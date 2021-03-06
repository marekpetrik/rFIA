bioStarter <- function(x,
                       db,
                       grpBy_quo = NULL,
                       polys = NULL,
                       returnSpatial = FALSE,
                       bySpecies = FALSE,
                       bySizeClass = FALSE,
                       landType = 'forest',
                       treeType = 'live',
                       method = 'TI',
                       lambda = .5,
                       treeDomain = NULL,
                       areaDomain = NULL,
                       totals = FALSE,
                       byPlot = FALSE,
                       nCores = 1,
                       remote,
                       mr){

  reqTables <- c('PLOT', 'TREE', 'COND', 'POP_PLOT_STRATUM_ASSGN', 'POP_ESTN_UNIT', 'POP_EVAL',
                 'POP_STRATUM', 'POP_EVAL_TYP', 'POP_EVAL_GRP')
  if (remote){
    ## Store the original parameters here
    params <- db

    ## Read in one state at a time
    db <- readFIA(dir = db$dir, common = db$common,
                  tables = reqTables, states = x, ## x is the vector of state names
                  nCores = nCores)

    ## If a clip was specified, run it now
    if ('mostRecent' %in% names(params)){
      db <- clipFIA(db, mostRecent = params$mostRecent,
                    mask = params$mask, matchEval = params$matchEval,
                    evalid = params$evalid, designCD = params$designCD,
                    nCores = nCores)
    }

  }else {
    ## Really only want the required tables
    db <- db[names(db) %in% reqTables]
  }



  ## Need a plotCN, and a new ID
  db$PLOT <- db$PLOT %>% mutate(PLT_CN = CN,
                                pltID = paste(UNITCD, STATECD, COUNTYCD, PLOT, sep = '_'))

  ##  don't have to change original code
  #grpBy_quo <- enquo(grpBy)

  # Probably cheating, but it works
  if (quo_name(grpBy_quo) != 'NULL'){
    ## Have to join tables to run select with this object type
    plt_quo <- filter(db$PLOT, !is.na(PLT_CN))
    ## We want a unique error message here to tell us when columns are not present in data
    d_quo <- tryCatch(
      error = function(cnd) {
        return(0)
      },
      plt_quo[10,] %>% # Just the first row
        left_join(select(db$COND, PLT_CN, names(db$COND)[names(db$COND) %in% names(db$PLOT) == FALSE]), by = 'PLT_CN') %>%
        inner_join(select(db$TREE, PLT_CN, names(db$TREE)[names(db$TREE) %in% c(names(db$PLOT), names(db$COND)) == FALSE]), by = 'PLT_CN') %>%
        select(!!grpBy_quo)
    )

    # If column doesnt exist, just returns 0, not a dataframe
    if (is.null(nrow(d_quo))){
      grpName <- quo_name(grpBy_quo)
      stop(paste('Columns', grpName, 'not found in PLOT, TREE, or COND tables. Did you accidentally quote the variables names? e.g. use grpBy = ECOSUBCD (correct) instead of grpBy = "ECOSUBCD". ', collapse = ', '))
    } else {
      # Convert to character
      grpBy <- names(d_quo)
    }
  } else {
    grpBy <- NULL
  }

  reqTables <- c('PLOT', 'TREE', 'COND', 'POP_PLOT_STRATUM_ASSGN', 'POP_ESTN_UNIT', 'POP_EVAL',
                 'POP_STRATUM', 'POP_EVAL_TYP', 'POP_EVAL_GRP')

  if (!is.null(polys) & first(class(polys)) %in% c('sf', 'SpatialPolygons', 'SpatialPolygonsDataFrame') == FALSE){
    stop('polys must be spatial polygons object of class sp or sf. ')
  }
  if (landType %in% c('timber', 'forest') == FALSE){
    stop('landType must be one of: "forest" or "timber".')
  }
  if (any(reqTables %in% names(db) == FALSE)){
    missT <- reqTables[reqTables %in% names(db) == FALSE]
    stop(paste('Tables', paste (as.character(missT), collapse = ', '), 'not found in object db.'))
  }
  if (str_to_upper(method) %in% c('TI', 'SMA', 'LMA', 'EMA', 'ANNUAL') == FALSE) {
    warning(paste('Method', method, 'unknown. Defaulting to Temporally Indifferent (TI).'))
  }

  # I like a unique ID for a plot through time
  if (byPlot) {grpBy <- c('pltID', grpBy)}
  # Save original grpBy for pretty return with spatial objects
  grpByOrig <- grpBy

  ## IF the object was clipped
  if ('prev' %in% names(db$PLOT)){
    ## Only want the current plots, no grm
    db$PLOT <- filter(db$PLOT, prev == 0)
  }

  ### DEAL WITH TEXAS
  if (any(db$POP_EVAL$STATECD %in% 48)){
    ## Will require manual updates
    txIDS <- db$POP_EVAL %>%
      filter(STATECD %in% 48) %>%
      filter(END_INVYR < 2017) %>%
      filter(END_INVYR > 2006) %>%
      ## Removing any inventory that references east or west, sorry
      filter(str_detect(str_to_upper(EVAL_DESCR), 'EAST', negate = TRUE) &
               str_detect(str_to_upper(EVAL_DESCR), 'WEST', negate = TRUE))
    db$POP_EVAL <- bind_rows(filter(db$POP_EVAL, !(STATECD %in% 48)), txIDS)
  }

  ### AREAL SUMMARY PREP
  if(!is.null(polys)) {
    # # Convert polygons to an sf object
    # polys <- polys %>%
    #   as('sf')%>%
    #   mutate_if(is.factor,
    #             as.character)
    # ## A unique ID
    # polys$polyID <- 1:nrow(polys)
    #
    # # Add shapefile names to grpBy
    grpBy = c(grpBy, 'polyID')

    ## Make plot data spatial, projected same as polygon layer
    pltSF <- select(db$PLOT, c('LON', 'LAT', pltID)) %>%
      filter(!is.na(LAT) & !is.na(LON)) %>%
      distinct(pltID, .keep_all = TRUE)
    coordinates(pltSF) <- ~LON+LAT
    proj4string(pltSF) <- '+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs'
    pltSF <- as(pltSF, 'sf') %>%
      st_transform(crs = st_crs(polys))

    ## Split up polys
    polyList <- split(polys, as.factor(polys$polyID))
    suppressWarnings({suppressMessages({
      ## Compute estimates in parallel -- Clusters in windows, forking otherwise
      if (Sys.info()['sysname'] == 'Windows'){
        cl <- makeCluster(nCores)
        clusterEvalQ(cl, {
          library(dplyr)
          library(stringr)
          library(rFIA)
        })
        out <- parLapply(cl, X = names(polyList), fun = areal_par, pltSF, polyList)
        #stopCluster(cl) # Keep the cluster active for the next run
      } else { # Unix systems
        out <- mclapply(names(polyList), FUN = areal_par, pltSF, polyList, mc.cores = nCores)
      }
    })})
    pltSF <- bind_rows(out)

    # A warning
    if (length(unique(pltSF$pltID)) < 1){
      stop('No plots in db overlap with polys.')
    }
    ## Add polygon names to PLOT
    db$PLOT <- db$PLOT %>%
      left_join(select(pltSF, polyID, pltID), by = 'pltID')

    # Test if any polygons cross state boundaries w/ different recent inventory years (continued w/in loop)
    if ('mostRecent' %in% names(db) & length(unique(db$POP_EVAL$STATECD)) > 1){
      mergeYears <- pltSF %>%
        right_join(select(db$PLOT, PLT_CN, pltID), by = 'pltID') %>%
        inner_join(select(db$POP_PLOT_STRATUM_ASSGN, c('PLT_CN', 'EVALID', 'STATECD')), by = 'PLT_CN') %>%
        inner_join(select(db$POP_EVAL, c('EVALID', 'END_INVYR')), by = 'EVALID') %>%
        group_by(polyID) %>%
        summarize(maxYear = max(END_INVYR, na.rm = TRUE))
    }

    ## TO RETURN SPATIAL PLOTS
  }
  if (byPlot & returnSpatial){
    grpBy <- c(grpBy, 'LON', 'LAT')
  } # END AREAL

  ## Build domain indicator function which is 1 if observation meets criteria, and 0 otherwise
  # Land type domain indicator
  if (tolower(landType) == 'forest'){
    db$COND$landD <- ifelse(db$COND$COND_STATUS_CD == 1, 1, 0)
  } else if (tolower(landType) == 'timber'){
    db$COND$landD <- ifelse(db$COND$COND_STATUS_CD == 1 & db$COND$SITECLCD %in% c(1, 2, 3, 4, 5, 6) & db$COND$RESERVCD == 0, 1, 0)
  }
  # Tree Type domain indicator
  if (tolower(treeType) == 'live'){
    db$TREE$typeD <- ifelse(db$TREE$STATUSCD == 1, 1, 0)
  } else if (tolower(treeType) == 'dead'){
    db$TREE$typeD <- ifelse(db$TREE$STATUSCD == 2 & db$TREE$STANDING_DEAD_CD == 1, 1, 0)
  } else if (tolower(treeType) == 'gs'){
    db$TREE$typeD <- ifelse(db$TREE$STATUSCD == 1 & db$TREE$DIA >= 5 & db$TREE$TREECLCD == 2, 1, 0)
  } else if (tolower(treeType) == 'all'){
    db$TREE$typeD <- 1
  }
  # update spatial domain indicator
  if(!is.null(polys)){
    db$PLOT$sp <- ifelse(db$PLOT$pltID %in% pltSF$pltID, 1, 0)
  } else {
    db$PLOT$sp <- 1
  }

  # User defined domain indicator for area (ex. specific forest type)
  pcEval <- left_join(db$PLOT, select(db$COND, -c('STATECD', 'UNITCD', 'COUNTYCD', 'INVYR', 'PLOT')), by = 'PLT_CN')
  #areaDomain <- substitute(areaDomain)
  pcEval$aD <- rlang::eval_tidy(areaDomain, pcEval) ## LOGICAL, THIS IS THE DOMAIN INDICATOR
  if(!is.null(pcEval$aD)) pcEval$aD[is.na(pcEval$aD)] <- 0 # Make NAs 0s. Causes bugs otherwise
  if(is.null(pcEval$aD)) pcEval$aD <- 1 # IF NULL IS GIVEN, THEN ALL VALUES TRUE
  pcEval$aD <- as.numeric(pcEval$aD)
  db$COND <- left_join(db$COND, select(pcEval, c('PLT_CN', 'CONDID', 'aD')), by = c('PLT_CN', 'CONDID')) %>%
    mutate(aD_c = aD)
  aD_p <- pcEval %>%
    group_by(PLT_CN) %>%
    summarize(aD_p = as.numeric(any(aD > 0)))
  db$PLOT <- left_join(db$PLOT, aD_p, by = 'PLT_CN')
  rm(pcEval)

  # Same as above for tree (ex. trees > 20 ft tall)
  #treeDomain <- substitute(treeDomain)
  tD <- rlang::eval_tidy(treeDomain, db$TREE) ## LOGICAL, THIS IS THE DOMAIN INDICATOR
  if(!is.null(tD)) tD[is.na(tD)] <- 0 # Make NAs 0s. Causes bugs otherwise
  if(is.null(tD)) tD <- 1 # IF NULL IS GIVEN, THEN ALL VALUES TRUE
  db$TREE$tD <- as.numeric(tD)

  ### Snag the EVALIDs that are needed
  db$POP_EVAL<- db$POP_EVAL %>%
    select('CN', 'END_INVYR', 'EVALID', 'ESTN_METHOD', STATECD) %>%
    inner_join(select(db$POP_EVAL_TYP, c('EVAL_CN', 'EVAL_TYP')), by = c('CN' = 'EVAL_CN')) %>%
    filter(EVAL_TYP == 'EXPVOL' | EVAL_TYP == 'EXPCURR') %>%
    filter(!is.na(END_INVYR) & !is.na(EVALID) & END_INVYR >= 2003) %>%
    distinct(END_INVYR, EVALID, .keep_all = TRUE)


  ## If a most-recent subset, make sure that we don't get two reporting years in
  ## western states
  if (mr) {
    db$POP_EVAL <- db$POP_EVAL %>%
      group_by(EVAL_TYP, STATECD) %>%
      filter(END_INVYR == max(END_INVYR, na.rm = TRUE)) %>%
      ungroup()
  }

  ## Cut STATECD
  db$POP_EVAL <- select(db$POP_EVAL, -c(STATECD))

  ### The population tables
  pops <- select(db$POP_EVAL, c('EVALID', 'ESTN_METHOD', 'CN', 'END_INVYR', 'EVAL_TYP')) %>%
    rename(EVAL_CN = CN) %>%
    left_join(select(db$POP_ESTN_UNIT, c('CN', 'EVAL_CN', 'AREA_USED', 'P1PNTCNT_EU')), by = c('EVAL_CN')) %>%
    rename(ESTN_UNIT_CN = CN) %>%
    left_join(select(db$POP_STRATUM, c('ESTN_UNIT_CN', 'EXPNS', 'P2POINTCNT', 'CN', 'P1POINTCNT', 'ADJ_FACTOR_SUBP', 'ADJ_FACTOR_MICR', "ADJ_FACTOR_MACR")), by = c('ESTN_UNIT_CN')) %>%
    rename(STRATUM_CN = CN) %>%
    left_join(select(db$POP_PLOT_STRATUM_ASSGN, c('STRATUM_CN', 'PLT_CN', 'INVYR', 'STATECD')), by = 'STRATUM_CN') %>%
    ungroup() %>%
    mutate_if(is.factor,
              as.character)

  ### Which estimator to use?
  if (str_to_upper(method) %in% c('ANNUAL')){
    ## Want to use the year where plots are measured, no repeats
    ## Breaking this up into pre and post reporting becuase
    ## Estimation units get weird on us otherwise
    popOrig <- pops
    pops <- pops %>%
      group_by(STATECD) %>%
      filter(END_INVYR == INVYR) %>%
      ungroup()

    prePops <- popOrig %>%
      group_by(STATECD) %>%
      filter(INVYR < min(END_INVYR, na.rm = TRUE)) %>%
      distinct(PLT_CN, .keep_all = TRUE) %>%
      ungroup()

    pops <- bind_rows(pops, prePops) %>%
      mutate(YEAR = INVYR)

  } else {     # Otherwise temporally indifferent
    pops <- rename(pops, YEAR = END_INVYR)
  }

  ## P2POINTCNT column is NOT consistent for annnual estimates, plots
  ## within individual strata and est units are related to different INVYRs
  p2_INVYR <- pops %>%
    group_by(ESTN_UNIT_CN, STRATUM_CN, INVYR) %>%
    summarize(P2POINTCNT_INVYR = length(unique(PLT_CN)))
  ## Want a count of p2 points / eu, gets screwed up with grouping below
  p2eu_INVYR <- p2_INVYR %>%
    distinct(ESTN_UNIT_CN, STRATUM_CN, INVYR, .keep_all = TRUE) %>%
    group_by(ESTN_UNIT_CN, INVYR) %>%
    summarize(p2eu_INVYR = sum(P2POINTCNT_INVYR, na.rm = TRUE))
  p2eu <- pops %>%
    distinct(ESTN_UNIT_CN, STRATUM_CN, .keep_all = TRUE) %>%
    group_by(ESTN_UNIT_CN) %>%
    summarize(p2eu = sum(P2POINTCNT, na.rm = TRUE))

  ## Rejoin
  pops <- pops %>%
    left_join(p2_INVYR, by = c('ESTN_UNIT_CN', 'STRATUM_CN', 'INVYR')) %>%
    left_join(p2eu_INVYR, by = c('ESTN_UNIT_CN', 'INVYR')) %>%
    left_join(p2eu, by = 'ESTN_UNIT_CN')


  ## Recode a few of the estimation methods to make things easier below
  pops$ESTN_METHOD = recode(.x = pops$ESTN_METHOD,
                            `Post-Stratification` = 'strat',
                            `Stratified random sampling` = 'strat',
                            `Double sampling for stratification` = 'double',
                            `Simple random sampling` = 'simple',
                            `Subsampling units of unequal size` = 'simple')


  ## Add species to groups
  if (bySpecies) {
    db$TREE <- db$TREE %>%
      left_join(select(intData$REF_SPECIES_2018, c('SPCD','COMMON_NAME', 'GENUS', 'SPECIES')), by = 'SPCD') %>%
      mutate(SCIENTIFIC_NAME = paste(GENUS, SPECIES, sep = ' ')) %>%
      mutate_if(is.factor,
                as.character)
    grpBy <- c(grpBy, 'SPCD', 'COMMON_NAME', 'SCIENTIFIC_NAME')
    grpByOrig <- c(grpByOrig, 'SPCD', 'COMMON_NAME', 'SCIENTIFIC_NAME')
  }

  ## Break into size classes
  if (bySizeClass){
    grpBy <- c(grpBy, 'sizeClass')
    grpByOrig <- c(grpByOrig, 'sizeClass')
    db$TREE$sizeClass <- makeClasses(db$TREE$DIA, interval = 2, numLabs = TRUE)
    db$TREE <- db$TREE[!is.na(db$TREE$sizeClass),]
  }


  # Seperate area grouping names, (ex. TPA red oak in total land area of ingham county, rather than only area where red oak occurs)
  if (!is.null(polys)){
    aGrpBy <- c(grpBy[grpBy %in% names(db$PLOT) | grpBy %in% names(db$COND) | grpBy %in% names(pltSF)])
  } else {
    aGrpBy <- c(grpBy[grpBy %in% names(db$PLOT) | grpBy %in% names(db$COND)])
  }

  ## Only the necessary plots for EVAL of interest
  db$PLOT <- filter(db$PLOT, PLT_CN %in% pops$PLT_CN)

  ## Narrow up the tables to the necessary variables, reduces memory load
  ## sent out the cores
  ## Which grpByNames are in which table? Helps us subset below
  grpP <- names(db$PLOT)[names(db$PLOT) %in% grpBy]
  grpC <- names(db$COND)[names(db$COND) %in% grpBy & names(db$COND) %in% grpP == FALSE]
  grpT <- names(db$TREE)[names(db$TREE) %in% grpBy & names(db$TREE) %in% c(grpP, grpC) == FALSE]


  ### Only joining tables necessary to produce plot level estimates
  db$PLOT <- select(ungroup(db$PLOT), PLT_CN, STATECD, COUNTYCD, MACRO_BREAKPOINT_DIA, INVYR, MEASYEAR, PLOT_STATUS_CD, all_of(grpP), aD_p, sp)
  db$COND <- select(db$COND, 'PLT_CN', 'CONDPROP_UNADJ', 'PROP_BASIS', 'COND_STATUS_CD', 'CONDID', all_of(grpC), 'aD_c', 'landD')
  db$TREE <- select(db$TREE, 'PLT_CN', 'CONDID', 'DIA', 'SPCD', 'TPA_UNADJ', 'SUBP', 'TREE', all_of(grpT), 'tD', 'typeD',
                                'VOLCFNET', 'VOLCSNET', 'DRYBIO_AG', 'DRYBIO_BG', 'CARBON_AG', 'CARBON_BG')


  ## Merging state and county codes
  plts <- split(db$PLOT, as.factor(paste(db$PLOT$COUNTYCD, db$PLOT$STATECD, sep = '_')))
  #plts <- split(db$PLOT, as.factor(db$PLOT$STATECD))

  suppressWarnings({
    ## Compute estimates in parallel -- Clusters in windows, forking otherwise
    if (Sys.info()['sysname'] == 'Windows'){
      cl <- makeCluster(nCores)
      clusterEvalQ(cl, {
        library(dplyr)
        library(stringr)
        library(rFIA)
      })
      out <- parLapply(cl, X = names(plts), fun = bioHelper1, plts, db, grpBy, aGrpBy, byPlot)
      #stopCluster(cl) # Keep the cluster active for the next run
    } else { # Unix systems
      out <- mclapply(names(plts), FUN = bioHelper1, plts, db, grpBy, aGrpBy, byPlot, mc.cores = nCores)
    }
  })

  if (byPlot){

    ## back to dataframes
    out <- unlist(out, recursive = FALSE)
    tOut <- bind_rows(out[names(out) == 't'])
    ## Make it spatial
    if (returnSpatial){
      tOut <- tOut %>%
        filter(!is.na(LAT) & !is.na(LON)) %>%
        st_as_sf(coords = c('LON', 'LAT'),
                 crs = '+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs')
      grpBy <- grpBy[grpBy %in% c('LAT', 'LON') == FALSE]

    }

    out <- list(tEst = tOut, grpBy = grpBy, aGrpBy = aGrpBy, grpByOrig = grpByOrig)
    ## Population estimation
  } else {
    ## back to dataframes
    out <- unlist(out, recursive = FALSE)
    a <- bind_rows(out[names(out) == 'a'])
    t <- bind_rows(out[names(out) == 't'])


    ## Adding YEAR to groups
    grpBy <- c('YEAR', grpBy)
    aGrpBy <- c('YEAR', aGrpBy)


    ## Splitting up by STATECD and groups of 25 ESTN_UNIT_CNs
    #estunit <- distinct(pops, ESTN_UNIT_CN) #%>%
    #mutate(estID)

    #estID <- seq(1, nrow(estunit), 50)
    #estunit$estID <- rep_len(estID, length.out = nrow(estunit))
    #pops <- pops %>%
    #  left_join(estunit, by = 'ESTN_UNIT_CN') #%>%
    #mutate(estBreaks = )

    #popState <- split(pops, as.factor(pops$estID))
    popState <- split(pops, as.factor(pops$STATECD))
    #
    suppressWarnings({
      ## Compute estimates in parallel -- Clusters in windows, forking otherwise
      if (Sys.info()['sysname'] == 'Windows'){
        ## Use the same cluster as above
        # cl <- makeCluster(nCores)
        # clusterEvalQ(cl, {
        #   library(dplyr)
        #   library(stringr)
        #   library(rFIA)
        # })
        out <- parLapply(cl, X = names(popState), fun = bioHelper2, popState, a, t, grpBy, aGrpBy, method)
        stopCluster(cl)
      } else { # Unix systems
        out <- mclapply(names(popState), FUN = bioHelper2, popState, a, t, grpBy, aGrpBy, method, mc.cores = nCores)
      }
    })
    ## back to dataframes
    out <- unlist(out, recursive = FALSE)
    aEst <- bind_rows(out[names(out) == 'aEst'])
    tEst <- bind_rows(out[names(out) == 'tEst'])


    ##### ----------------- MOVING AVERAGES
    if (str_to_upper(method) %in% c("SMA", 'EMA', 'LMA')){
      ### ---- SIMPLE MOVING AVERAGE
      if (str_to_upper(method) == 'SMA'){
        ## Assuming a uniform weighting scheme
        wgts <- pops %>%
          group_by(ESTN_UNIT_CN) %>%
          summarize(wgt = 1 / length(unique(INVYR)))

        aEst <- left_join(aEst, wgts, by = 'ESTN_UNIT_CN')
        tEst <- left_join(tEst, wgts, by = 'ESTN_UNIT_CN')

        #### ----- Linear MOVING AVERAGE
      } else if (str_to_upper(method) == 'LMA'){
        wgts <- pops %>%
          distinct(YEAR, ESTN_UNIT_CN, INVYR, .keep_all = TRUE) %>%
          arrange(YEAR, ESTN_UNIT_CN, INVYR) %>%
          group_by(as.factor(YEAR), as.factor(ESTN_UNIT_CN)) %>%
          mutate(rank = min_rank(INVYR))

        ## Want a number of INVYRs per EU
        neu <- wgts %>%
          group_by(ESTN_UNIT_CN) %>%
          summarize(n = sum(rank, na.rm = TRUE))

        ## Rejoining and computing wgts
        wgts <- wgts %>%
          left_join(neu, by = 'ESTN_UNIT_CN') %>%
          mutate(wgt = rank / n) %>%
          ungroup() %>%
          select(ESTN_UNIT_CN, INVYR, wgt)

        aEst <- left_join(aEst, wgts, by = c('ESTN_UNIT_CN', 'INVYR'))
        tEst <- left_join(tEst, wgts, by = c('ESTN_UNIT_CN', 'INVYR'))

        #### ----- EXPONENTIAL MOVING AVERAGE
      } else if (str_to_upper(method) == 'EMA'){
        wgts <- pops %>%
          distinct(YEAR, ESTN_UNIT_CN, INVYR, .keep_all = TRUE) %>%
          arrange(YEAR, ESTN_UNIT_CN, INVYR) %>%
          group_by(as.factor(YEAR), as.factor(ESTN_UNIT_CN)) %>%
          mutate(rank = min_rank(INVYR))


        if (length(lambda) < 2){
          ## Want sum of weighitng functions
          neu <- wgts %>%
            mutate(l = lambda) %>%
            group_by(ESTN_UNIT_CN) %>%
            summarize(l = 1 - first(lambda),
                      sumwgt = sum(l*(1-l)^(1-rank), na.rm = TRUE))

          ## Rejoining and computing wgts
          wgts <- wgts %>%
            left_join(neu, by = 'ESTN_UNIT_CN') %>%
            mutate(wgt = l*(1-l)^(1-rank) / sumwgt) %>%
            ungroup() %>%
            select(ESTN_UNIT_CN, INVYR, wgt)
        } else {
          grpBy <- c('lambda', grpBy)
          aGrpBy <- c('lambda', aGrpBy)
          ## Duplicate weights for each level of lambda
          yrWgts <- list()
          for (i in 1:length(unique(lambda))) {
            yrWgts[[i]] <- mutate(wgts, lambda = lambda[i])
          }
          wgts <- bind_rows(yrWgts)
          ## Want sum of weighitng functions
          neu <- wgts %>%
            group_by(lambda, ESTN_UNIT_CN) %>%
            summarize(l = 1 - first(lambda),
                      sumwgt = sum(l*(1-l)^(1-rank), na.rm = TRUE))

          ## Rejoining and computing wgts
          wgts <- wgts %>%
            left_join(neu, by = c('lambda', 'ESTN_UNIT_CN')) %>%
            mutate(wgt = l*(1-l)^(1-rank) / sumwgt) %>%
            ungroup() %>%
            select(lambda, ESTN_UNIT_CN, INVYR, wgt)
        }

        aEst <- left_join(aEst, wgts, by = c('ESTN_UNIT_CN', 'INVYR'))
        tEst <- left_join(tEst, wgts, by = c('ESTN_UNIT_CN', 'INVYR'))

      }

      ### Applying the weights
      # Area
      aEst <- aEst %>%
        mutate_at(vars(aEst), ~(.*wgt)) %>%
        mutate_at(vars(aVar), ~(.*(wgt^2))) %>%
        group_by(ESTN_UNIT_CN, .dots = aGrpBy) %>%
        summarize_at(vars(aEst:plotIn_AREA), sum, na.rm = TRUE)


      tEst <- tEst %>%
        mutate_at(vars(nvEst:ctEst), ~(.*wgt)) %>%
        mutate_at(vars(nvVar:cvEst_ct), ~(.*(wgt^2))) %>%
        group_by(ESTN_UNIT_CN, .dots = grpBy) %>%
        summarize_at(vars(nvEst:plotIn_TREE), sum, na.rm = TRUE)

    }


    out <- list(tEst = tEst, aEst = aEst, grpBy = grpBy, aGrpBy = aGrpBy, grpByOrig = grpByOrig)
  }

  return(out)

}






#' @export
biomass <- function(db,
                       grpBy = NULL,
                       polys = NULL,
                       returnSpatial = FALSE,
                       bySpecies = FALSE,
                       bySizeClass = FALSE,
                       landType = 'forest',
                       treeType = 'live',
                       method = 'TI',
                       lambda = .5,
                       treeDomain = NULL,
                       areaDomain = NULL,
                       totals = FALSE,
                       variance = FALSE,
                       byPlot = FALSE,
                       nCores = 1) {

  ##  don't have to change original code
  grpBy_quo <- rlang::enquo(grpBy)
  areaDomain <- rlang::enquo(areaDomain)
  treeDomain <- rlang::enquo(treeDomain)

  ### Is DB remote?
  remote <- ifelse(class(db) == 'Remote.FIA.Database', 1, 0)
  if (remote){

    iter <- db$states

    ## In memory
  } else {
    ## Some warnings
    if (class(db) != "FIA.Database"){
      stop('db must be of class "FIA.Database". Use readFIA() to load your FIA data.')
    }

    ## an iterator for remote
    iter <- 1

  }

  ## Check for a most recent subset
  if (remote){
    if ('mostRecent' %in% names(db)){
      mr = db$mostRecent # logical
    } else {
      mr = FALSE
    }
    ## In-memory
  } else {
    if ('mostRecent' %in% names(db)){
      mr = TRUE
    } else {
      mr = FALSE
    }
  }

  ### AREAL SUMMARY PREP
  if(!is.null(polys)) {
    # Convert polygons to an sf object
    polys <- polys %>%
      as('sf')%>%
      mutate_if(is.factor,
                as.character)
    ## A unique ID
    polys$polyID <- 1:nrow(polys)
  }



  ## Run the main portion
  out <- lapply(X = iter, FUN = bioStarter, db,
                grpBy_quo = grpBy_quo, polys, returnSpatial,
                bySpecies, bySizeClass,
                landType, treeType, method,
                lambda, treeDomain, areaDomain,
                totals, byPlot, nCores, remote, mr)
  ## Bring the results back
  out <- unlist(out, recursive = FALSE)
  aEst <- bind_rows(out[names(out) == 'aEst'])
  tEst <- bind_rows(out[names(out) == 'tEst'])
  grpBy <- out[names(out) == 'grpBy'][[1]]
  aGrpBy <- out[names(out) == 'aGrpBy'][[1]]
  grpByOrig <- out[names(out) == 'grpByOrig'][[1]]


  if (byPlot){
    ## back to dataframes
    tOut <- tEst

  } else {

    suppressMessages({suppressWarnings({
      ## If a clip was specified, handle the reporting years
      if (mr){
        ## If a most recent subset, ignore differences in reporting years across states
        ## instead combine most recent information from each state
        # ID mr years by group
        maxyearsT <- tEst %>%
          select(grpBy) %>%
          group_by(.dots = grpBy[!c(grpBy %in% 'YEAR')]) %>%
          summarise(YEAR = max(YEAR, na.rm = TRUE))
        maxyearsA <- aEst %>%
          select(aGrpBy) %>%
          group_by(.dots = aGrpBy[!c(aGrpBy %in% 'YEAR')]) %>%
          summarise(YEAR = max(YEAR, na.rm = TRUE))

        # Combine estimates
        aEst <- aEst %>%
          ungroup() %>%
          select(-c(YEAR)) %>%
          left_join(maxyearsA, by = aGrpBy[!c(aGrpBy %in% 'YEAR')])
        tEst <- tEst %>%
          ungroup() %>%
          select(-c(YEAR)) %>%
          left_join(maxyearsT, by = grpBy[!c(grpBy %in% 'YEAR')])

      }
    })})

    ##---------------------  TOTALS and RATIOS
    # Area
    # aTotal <- aEst %>%
    #   group_by(.dots = aGrpBy) %>%
    #   summarize(aEst = sum(aEst, na.rm = TRUE),
    #             aVar = sum(aVar, na.rm = TRUE),
    #             #AREA_TOTAL_SE = sqrt(aVar) / AREA_TOTAL * 100,
    #             plotIn_AREA = sum(plotIn_AREA, na.rm = TRUE))
    aTotal <- aEst %>%
      group_by(.dots = aGrpBy) %>%
      summarize_all(sum,na.rm = TRUE)
    # summarize(AREA_TOTAL = sum(aEst, na.rm = TRUE),
    #           aVar = sum(aVar, na.rm = TRUE),
    #           AREA_TOTAL_SE = sqrt(aVar) / AREA_TOTAL * 100,
      #           nPlots_AREA = sum(plotIn_AREA, na.rm = TRUE))
    # Tree
    tTotal <- tEst %>%
      group_by(.dots = grpBy) %>%
      summarize_all(sum,na.rm = TRUE)


    suppressWarnings({
      ## Bring them together
      tOut <- tTotal %>%
        left_join(aTotal, by = aGrpBy) %>%
        # Renaming, computing ratios, and SE
        mutate(AREA_TOTAL = aEst,
               NETVOL_TOTAL = nvEst,
               SAWVOL_TOTAL = svEst,
               BIO_AG_TOTAL = bagEst,
               BIO_BG_TOTAL = bbgEst,
               BIO_TOTAL = btEst,
               CARB_AG_TOTAL = cagEst,
               CARB_BG_TOTAL = cbgEst,
               CARB_TOTAL = ctEst,
               ## Ratios
               NETVOL_ACRE = NETVOL_TOTAL / AREA_TOTAL,
               SAWVOL_ACRE = SAWVOL_TOTAL / AREA_TOTAL,
               BIO_AG_ACRE = BIO_AG_TOTAL / AREA_TOTAL,
               BIO_BG_ACRE = BIO_BG_TOTAL / AREA_TOTAL,
               BIO_ACRE = BIO_TOTAL / AREA_TOTAL,
               CARB_AG_ACRE = CARB_AG_TOTAL / AREA_TOTAL,
               CARB_BG_ACRE = CARB_BG_TOTAL / AREA_TOTAL,
               CARB_ACRE = CARB_TOTAL / AREA_TOTAL,
               ## Ratio Var
               nvaVar = (1/AREA_TOTAL^2) * (nvVar + (NETVOL_ACRE^2 * aVar) - 2 * NETVOL_ACRE * cvEst_nv),
               svaVar = (1/AREA_TOTAL^2) * (svVar + (SAWVOL_ACRE^2 * aVar) - 2 * SAWVOL_ACRE * cvEst_sv),
               baaVar = (1/AREA_TOTAL^2) * (bagVar + (BIO_AG_ACRE^2 * aVar) - 2 * BIO_AG_ACRE * cvEst_bag),
               bbaVar = (1/AREA_TOTAL^2) * (bbgVar + (BIO_BG_ACRE^2 * aVar) - 2 * BIO_BG_ACRE * cvEst_bbg),
               btaVar = (1/AREA_TOTAL^2) * (btVar + (BIO_ACRE^2 * aVar) - 2 * BIO_ACRE * cvEst_bt),
               caaVar = (1/AREA_TOTAL^2) * (cagVar + (CARB_AG_ACRE^2 * aVar) - 2 * CARB_AG_ACRE * cvEst_cag),
               cbaVar = (1/AREA_TOTAL^2) * (bbgVar + (CARB_BG_ACRE^2 * aVar) - 2 * CARB_BG_ACRE * cvEst_bbg),
               ctaVar = (1/AREA_TOTAL^2) * (ctVar + (CARB_ACRE^2 * aVar) - 2 * CARB_ACRE * cvEst_ct),
               ## SE RATIO
               NETVOL_ACRE_SE = sqrt(nvaVar) / NETVOL_ACRE *100,
               SAWVOL_ACRE_SE = sqrt(svaVar) / SAWVOL_ACRE *100,
               BIO_AG_ACRE_SE = sqrt(baaVar) / BIO_AG_ACRE *100,
               BIO_BG_ACRE_SE = sqrt(bbaVar) / BIO_BG_ACRE *100,
               BIO_ACRE_SE = sqrt(btaVar) / BIO_ACRE * 100,
               CARB_AG_ACRE_SE = sqrt(caaVar) / CARB_AG_ACRE *100,
               CARB_BG_ACRE_SE = sqrt(cbaVar) / CARB_BG_ACRE *100,
               CARB_ACRE_SE = sqrt(ctaVar) / CARB_ACRE *100,
               ## SE TOTAL
               AREA_TOTAL_SE = sqrt(aVar) / AREA_TOTAL *100,
               NETVOL_TOTAL_SE = sqrt(nvVar) / NETVOL_TOTAL *100,
               SAWVOL_TOTAL_SE = sqrt(svVar) / SAWVOL_TOTAL *100,
               BIO_AG_TOTAL_SE = sqrt(bagVar) / BIO_AG_TOTAL *100,
               BIO_BG_TOTAL_SE = sqrt(bbgVar) / BIO_BG_TOTAL *100,
               BIO_TOTAL_SE = sqrt(btVar) / BIO_TOTAL *100,
               CARB_AG_TOTAL_SE = sqrt(cagVar) / CARB_AG_TOTAL *100,
               CARB_BG_TOTAL_SE = sqrt(cbgVar) / CARB_BG_TOTAL *100,
               CARB_TOTAL_SE = sqrt(ctVar) / CARB_TOTAL *100,

               ## VAR RATIO
               NETVOL_ACRE_VAR = nvaVar,
               SAWVOL_ACRE_VAR = svaVar,
               BIO_AG_ACRE_VAR = baaVar,
               BIO_BG_ACRE_VAR = bbaVar,
               BIO_ACRE_VAR = btaVar,
               CARB_AG_ACRE_VAR = caaVar,
               CARB_BG_ACRE_VAR = cbaVar,
               CARB_ACRE_VAR = ctaVar,
               ## VAR TOTAL
               AREA_TOTAL_VAR = aVar,
               NETVOL_TOTAL_VAR = nvVar,
               SAWVOL_TOTAL_VAR = svVar,
               BIO_AG_TOTAL_VAR = bagVar,
               BIO_BG_TOTAL_VAR = bbgVar,
               BIO_TOTAL_VAR = btVar,
               CARB_AG_TOTAL_VAR = cagVar,
               CARB_BG_TOTAL_VAR = cbgVar,
               CARB_TOTAL_VAR = ctVar,
               ## nPlots
               nPlots_TREE = plotIn_TREE,
               nPlots_AREA = plotIn_AREA)
    })


    if (totals) {

      if (variance){
        tOut <- tOut %>%
          select(grpBy, "NETVOL_ACRE","SAWVOL_ACRE","BIO_AG_ACRE","BIO_BG_ACRE",
                 "BIO_ACRE","CARB_AG_ACRE","CARB_BG_ACRE","CARB_ACRE","NETVOL_TOTAL",
                 "SAWVOL_TOTAL","BIO_AG_TOTAL","BIO_BG_TOTAL","BIO_TOTAL","CARB_AG_TOTAL",
                 "CARB_BG_TOTAL","CARB_TOTAL", "AREA_TOTAL","NETVOL_ACRE_VAR",
                 "SAWVOL_ACRE_VAR","BIO_AG_ACRE_VAR", "BIO_BG_ACRE_VAR", "BIO_ACRE_VAR",
                 "CARB_AG_ACRE_VAR","CARB_BG_ACRE_VAR","CARB_ACRE_VAR","NETVOL_TOTAL_VAR",
                 "SAWVOL_TOTAL_VAR",  "BIO_AG_TOTAL_VAR",  "BIO_BG_TOTAL_VAR",
                 "BIO_TOTAL_VAR", "CARB_AG_TOTAL_VAR", "CARB_BG_TOTAL_VAR", "CARB_TOTAL_VAR",
                 "AREA_TOTAL_VAR","nPlots_TREE","nPlots_AREA", 'N')

      } else {
        tOut <- tOut %>%
          select(grpBy, "NETVOL_ACRE","SAWVOL_ACRE","BIO_AG_ACRE","BIO_BG_ACRE",
                 "BIO_ACRE","CARB_AG_ACRE","CARB_BG_ACRE","CARB_ACRE","NETVOL_TOTAL",
                 "SAWVOL_TOTAL","BIO_AG_TOTAL","BIO_BG_TOTAL","BIO_TOTAL","CARB_AG_TOTAL",
                 "CARB_BG_TOTAL","CARB_TOTAL", "AREA_TOTAL","NETVOL_ACRE_SE",
                 "SAWVOL_ACRE_SE","BIO_AG_ACRE_SE", "BIO_BG_ACRE_SE", "BIO_ACRE_SE",
                 "CARB_AG_ACRE_SE","CARB_BG_ACRE_SE","CARB_ACRE_SE","NETVOL_TOTAL_SE",
                 "SAWVOL_TOTAL_SE",  "BIO_AG_TOTAL_SE",  "BIO_BG_TOTAL_SE",
                 "BIO_TOTAL_SE", "CARB_AG_TOTAL_SE", "CARB_BG_TOTAL_SE", "CARB_TOTAL_SE",
                 "AREA_TOTAL_SE","nPlots_TREE","nPlots_AREA")
      }



    } else {
      if (variance){
        tOut <- tOut %>%
          select(grpBy, "NETVOL_ACRE","SAWVOL_ACRE","BIO_AG_ACRE","BIO_BG_ACRE",
                 "BIO_ACRE","CARB_AG_ACRE","CARB_BG_ACRE","CARB_ACRE","NETVOL_ACRE_VAR",
                 "SAWVOL_ACRE_VAR","BIO_AG_ACRE_VAR", "BIO_BG_ACRE_VAR", "BIO_ACRE_VAR",
                 "CARB_AG_ACRE_VAR","CARB_BG_ACRE_VAR","CARB_ACRE_VAR","nPlots_TREE",
                 "nPlots_AREA", 'N')
      } else {
        tOut <- tOut %>%
          select(grpBy, "NETVOL_ACRE","SAWVOL_ACRE","BIO_AG_ACRE","BIO_BG_ACRE",
                 "BIO_ACRE","CARB_AG_ACRE","CARB_BG_ACRE","CARB_ACRE","NETVOL_ACRE_SE",
                 "SAWVOL_ACRE_SE","BIO_AG_ACRE_SE", "BIO_BG_ACRE_SE", "BIO_ACRE_SE",
                 "CARB_AG_ACRE_SE","CARB_BG_ACRE_SE","CARB_ACRE_SE","nPlots_TREE",
                 "nPlots_AREA")
      }

    }

    # Snag the names
    tNames <- names(tOut)[names(tOut) %in% grpBy == FALSE]

  }

  ## Pretty output
  tOut <- tOut %>%
    ungroup() %>%
    mutate_if(is.factor, as.character) %>%
    drop_na(grpBy) %>%
    arrange(YEAR) %>%
    as_tibble()


  # Return a spatial object
  if (!is.null(polys) & byPlot == FALSE) {
    ## NO IMPLICIT NA
    nospGrp <- unique(grpBy[grpBy %in% c('SPCD', 'SYMBOL', 'COMMON_NAME', 'SCIENTIFIC_NAME') == FALSE])
    nospSym <- syms(nospGrp)
    tOut <- complete(tOut, !!!nospSym)
    ## If species, we don't want unique combos of variables related to same species
    ## but we do want NAs in polys where species are present
    if (length(nospGrp) < length(grpBy)){
      spGrp <- unique(grpBy[grpBy %in% c('SPCD', 'SYMBOL', 'COMMON_NAME', 'SCIENTIFIC_NAME')])
      spSym <- syms(spGrp)
      tOut <- complete(tOut, nesting(!!!nospSym))
    }

    suppressMessages({suppressWarnings({
      tOut <- left_join(tOut, polys) %>%
        select(c('YEAR', grpByOrig, tNames, names(polys))) %>%
        filter(!is.na(polyID) & !is.na(nPlots_AREA))})})

    ## Makes it horrible to work with as a dataframe
    if (returnSpatial == FALSE) tOut <- select(tOut, -c(geometry))
  } else if (!is.null(polys) & byPlot){
    polys <- as.data.frame(polys)
    tOut <- left_join(tOut, select(polys, -c(geometry)), by = 'polyID')
  }


  ## For spatial plots
  if (returnSpatial & byPlot) grpBy <- grpBy[grpBy %in% c('LAT', 'LON') == FALSE]

  ## Above converts to tibble
  if (returnSpatial) tOut <- st_sf(tOut)
  # ## remove any duplicates in byPlot (artifact of END_INYR loop)
  if (byPlot) tOut <- unique(tOut)
  return(tOut)
}










