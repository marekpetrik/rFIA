growMortStarter <- function(x,
                            db,
                            grpBy_quo = NULL,
                            polys = NULL,
                            returnSpatial = FALSE,
                            bySpecies = FALSE,
                            bySizeClass = FALSE,
                            landType = 'forest',
                            treeType = 'all',
                            method = 'TI',
                            lambda = .5,
                            stateVar = 'TPA',
                            treeDomain = NULL,
                            areaDomain = NULL,
                            totals = FALSE,
                            byPlot = FALSE,
                            nCores = 1,
                            remote){

  reqTables <- c('PLOT', 'COND', 'TREE', 'TREE_GRM_COMPONENT', 'TREE_GRM_MIDPT',
                 'SUBP_COND_CHNG_MTRX',
                 'POP_PLOT_STRATUM_ASSGN', 'POP_ESTN_UNIT', 'POP_EVAL',
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

  } else {
    ## Really only want the required tables
    db <- db[names(db) %in% reqTables]
  }

  ## Need a plotCN
  db$TREE <- db[['TREE']] %>% mutate(TRE_CN = CN)
  ## Need a plotCN, and a new ID
  db$PLOT <- db$PLOT %>% mutate(PLT_CN = CN,
                                pltID = paste(UNITCD, STATECD, COUNTYCD, PLOT, sep = '_'))


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

  reqTables <- c('PLOT', 'TREE', 'TREE_GRM_COMPONENT', 'TREE_GRM_MIDPT', 'COND',
                 'POP_PLOT_STRATUM_ASSGN', 'POP_ESTN_UNIT', 'POP_EVAL',
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

  ## No EXP_GROW available for Western States, make sure we warn that values will be returned as 0
  # These states do not allow temporal queries. Things are extremely weird with their eval groups
  noGrow <- c(02,03,04,07,08,11,14,15,16, 30, 32, 35,43,49, 78)
  if(any(unique(db$PLOT$STATECD) %in% noGrow)){
    vState <- unique(db$PLOT$STATECD[db$PLOT$STATECD %in% noGrow])
    fancyName <- unique(intData$EVAL_GRP$STATE[intData$EVAL_GRP$STATECD %in% vState])
    warning(paste('Recruitment data unavailable for: ', toString(fancyName) , '. Returning 0 for all recruitment estimates which include these states.', sep = ''))
  }
  # These states do not allow change estimates.
  if(any(unique(db$PLOT$STATECD) %in% c(69, 72, 78, 15, 02))){
    vState <- unique(db$PLOT$STATECD[db$PLOT$STATECD %in% c(69, 72, 78, 15, 02)])
    fancyName <- unique(intData$EVAL_GRP$STATE[intData$EVAL_GRP$STATECD %in% vState])
    stop(paste('Growth & Mortality Estimates unavailable for: ', paste(as.character(fancyName), collapse = ', '), sep = ''))
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


  # I like a unique ID for a plot through time
  if (byPlot) {grpBy <- c('pltID', grpBy)}
  # Save original grpBy for pretty return with spatial objects
  grpByOrig <- grpBy

  ### AREAL SUMMARY PREP
  if(!is.null(polys)) {
    # # Convert polygons to an sf object
    # polys <- polys %>%
    #   as('sf')%>%
    #   mutate_if(is.factor,
    #             as.character)
    # ## A unique ID
    # polys$polyID <- 1:nrow(polys)

    # Add shapefile names to grpBy
    #grpBy = c(names(polys)[str_detect(names(polys), 'geometry') == FALSE], 'polyID', grpBy)
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
      left_join(pltSF, by = 'pltID')

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


  ### HANDLE THE STATE VARIABLE, only applying to the midpoint table for consistency
  if (str_to_upper(stateVar) == 'TPA'){
    db$TREE_GRM_MIDPT$state <- 1
    db$TREE$state_recr <- 1
  } else if (str_to_upper(stateVar) == 'BAA'){
    db$TREE_GRM_MIDPT$state <- basalArea(db$TREE_GRM_MIDPT$DIA)
    db$TREE$state_recr <- basalArea(db$TREE$DIA)
  } else if (str_to_upper(stateVar) == 'SAWVOL'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$VOLCSNET
    db$TREE$state_recr <- db$TREE$VOLCSNET
  } else if (str_to_upper(stateVar) == 'NETVOL'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$VOLCFNET
    db$TREE$state_recr <- db$TREE$VOLCFNET
  } else if (str_to_upper(stateVar) == 'BIO_AG'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$DRYBIO_AG
    db$TREE$state_recr <- db$TREE$DRYBIO_AG
  } else if (str_to_upper(stateVar) == 'BIO_BG'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$DRYBIO_BG
    db$TREE$state_recr <- db$TREE$DRYBIO_BG
  } else if (str_to_upper(stateVar) == 'BIO'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$DRYBIO_BG + db$TREE_GRM_MIDPT$DRYBIO_AG
    db$TREE$state_recr <- db$TREE$DRYBIO_BG + db$TREE$DRYBIO_AG
  } else if (str_to_upper(stateVar) == 'CARB_AG'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$DRYBIO_AG * .5
    db$TREE$state_recr <- db$TREE$DRYBIO_AG * .5
  } else if (str_to_upper(stateVar) == 'CARB_BG'){
    db$TREE_GRM_MIDPT$state <- db$TREE_GRM_MIDPT$DRYBIO_BG * .5
    db$TREE$state_recr <- db$TREE$DRYBIO_BG * .5
  } else if (str_to_upper(stateVar) == 'CARB'){
    db$TREE_GRM_MIDPT$state <- (db$TREE_GRM_MIDPT$DRYBIO_AG + db$TREE_GRM_MIDPT$DRYBIO_BG) * .5
    db$TREE$state_recr <- (db$TREE$DRYBIO_AG + db$TREE$DRYBIO_BG) * .5
  } else {
    stop(paste0('Method not known for stateVar: ', stateVar, '. Please choose one of: TPA, SAWVOL, NETVOL, BIO_AG, BIO_BG, BIO, CARB_AG, CARB_BG, or CARB.' ))
  }

  ## Build domain indicator function which is 1 if observation meets criteria, and 0 otherwise
  # Land type domain indicator
  if (tolower(landType) == 'forest'){
    db$COND$landD <- ifelse(db$COND$COND_STATUS_CD == 1, 1, 0)
    # Tree Type domain indicator
    if (tolower(treeType) == 'all'){
      db$TREE$typeD <- 1
      ## Rename some variables in grm
      db$TREE_GRM_COMPONENT <- rename(db$TREE_GRM_COMPONENT,
                                      TPAMORT_UNADJ = SUBP_TPAMORT_UNADJ_AL_FOREST,
                                      TPAREMV_UNADJ = SUBP_TPAREMV_UNADJ_AL_FOREST,
                                      TPAGROW_UNADJ = SUBP_TPAGROW_UNADJ_AL_FOREST,
                                      SUBPTYP_GRM = SUBP_SUBPTYP_GRM_AL_FOREST,
                                      COMPONENT = SUBP_COMPONENT_AL_FOREST) %>%
        mutate(TPARECR_UNADJ = case_when(
          is.na(COMPONENT) ~ NA_real_,
          COMPONENT %in% c('INGROWTH', 'CUT2', 'MORTALITY2') ~ TPAGROW_UNADJ,
          TRUE ~ 0))

    } else if (tolower(treeType) == 'gs'){
      # db$TREE <- db$TREE %>%
      #   mutate(typeD = case_when(
      #     STATUSCD %in% 1:2 & DIA >=5 ~ 1,
      #     STATUSCD == 3 & PREVDIA >=5 ~ 1,
      #     TRUE ~ 0))
      db$TREE$typeD <- 1
      db$TREE_GRM_COMPONENT <- rename(db$TREE_GRM_COMPONENT,
                                      TPAMORT_UNADJ = SUBP_TPAMORT_UNADJ_GS_FOREST,
                                      TPAREMV_UNADJ = SUBP_TPAREMV_UNADJ_GS_FOREST,
                                      TPAGROW_UNADJ = SUBP_TPAGROW_UNADJ_GS_FOREST,
                                      SUBPTYP_GRM = SUBP_SUBPTYP_GRM_GS_FOREST,
                                      COMPONENT = SUBP_COMPONENT_GS_FOREST)%>%
        mutate(TPARECR_UNADJ = case_when(
          is.na(COMPONENT) ~ NA_real_,
          COMPONENT %in% c('INGROWTH', 'CUT2', 'MORTALITY2') ~ TPAGROW_UNADJ,
          TRUE ~ 0))
    }
  } else if (tolower(landType) == 'timber'){
    db$COND$landD <- ifelse(db$COND$COND_STATUS_CD == 1 & db$COND$SITECLCD %in% c(1, 2, 3, 4, 5, 6) & db$COND$RESERVCD == 0, 1, 0)
    # Tree Type domain indicator
    if (tolower(treeType) == 'all'){
      db$TREE$typeD <- 1
      ## Rename some variables in grm
      db$TREE_GRM_COMPONENT <- rename(db$TREE_GRM_COMPONENT,
                                      TPAMORT_UNADJ = SUBP_TPAMORT_UNADJ_AL_TIMBER,
                                      TPAREMV_UNADJ = SUBP_TPAREMV_UNADJ_AL_TIMBER,
                                      TPAGROW_UNADJ = SUBP_TPAGROW_UNADJ_AL_TIMBER,
                                      SUBPTYP_GRM = SUBP_SUBPTYP_GRM_AL_TIMBER,
                                      COMPONENT = SUBP_COMPONENT_AL_TIMBER)%>%
        mutate(TPARECR_UNADJ = case_when(
          is.na(COMPONENT) ~ NA_real_,
          COMPONENT %in% c('INGROWTH', 'CUT2', 'MORTALITY2') ~ TPAGROW_UNADJ,
          TRUE ~ 0))

    } else if (tolower(treeType) == 'gs'){
      # db$TREE <- db$TREE %>%
      #   mutate(typeD = case_when(
      #     STATUSCD %in% 1:2 & DIA >=5 ~ 1,
      #     STATUSCD == 3 & PREVDIA >=5 ~ 1,
      #     TRUE ~ 0))
      db$TREE$typeD <- 1
      db$TREE_GRM_COMPONENT <- rename(db$TREE_GRM_COMPONENT,
                                      TPAMORT_UNADJ = SUBP_TPAMORT_UNADJ_GS_TIMBER,
                                      TPAREMV_UNADJ = SUBP_TPAREMV_UNADJ_GS_TIMBER,
                                      TPAGROW_UNADJ = SUBP_TPAGROW_UNADJ_GS_TIMBER,
                                      SUBPTYP_GRM = SUBP_SUBPTYP_GRM_GS_TIMBER,
                                      COMPONENT = SUBP_COMPONENT_GS_TIMBER)%>%
        mutate(TPARECR_UNADJ = case_when(
          is.na(COMPONENT) ~ NA_real_,
          COMPONENT %in% c('INGROWTH', 'CUT2', 'MORTALITY2') ~ TPAGROW_UNADJ,
          TRUE ~ 0))
    }
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


  ## What years are growth accounting years --> not all filled in
  ga <- db$POP_EVAL %>%
    group_by(END_INVYR) %>%
    summarize(ga = if_else(any(GROWTH_ACCT == 'Y'), 1, 0))


  ### Snag the EVALIDs that are needed
  db$POP_EVAL  <- db$POP_EVAL %>%
    left_join(ga, by = 'END_INVYR') %>%
    select('CN', 'END_INVYR', 'EVALID', 'ESTN_METHOD', 'GROWTH_ACCT', 'ga') %>%
    left_join(select(db$POP_EVAL_TYP, c('EVAL_CN', 'EVAL_TYP')), by = c('CN' = 'EVAL_CN')) %>%
    filter(EVAL_TYP %in% c('EXPGROW', 'EXPMORT', 'EXPREMV')) %>%
    filter(!is.na(END_INVYR) & !is.na(EVALID) & END_INVYR >= 2003) %>%
    distinct(END_INVYR, EVALID, .keep_all = TRUE)# %>%
  #group_by(END_INVYR) %>%
  #summarise(id = list(EVALID)

  ## Make an annual panel ID, associated with an INVYR

  ### The population tables
  pops <- select(db$POP_EVAL, c('EVALID', 'ESTN_METHOD', 'CN', 'GROWTH_ACCT', 'END_INVYR', 'EVAL_TYP')) %>%
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

  ## Merging state and county codes
  plts <- split(db$PLOT, as.factor(paste(db$PLOT$COUNTYCD, db$PLOT$STATECD, sep = '_')))

  suppressWarnings({
    ## Compute estimates in parallel -- Clusters in windows, forking otherwise
    if (Sys.info()['sysname'] == 'Windows'){
      cl <- makeCluster(nCores)
      clusterEvalQ(cl, {
        library(dplyr)
        library(stringr)
        library(rFIA)
      })
      out <- parLapply(cl, X = names(plts), fun = gmHelper1, plts, db, grpBy, aGrpBy, byPlot)
      #stopCluster(cl) # Keep the cluster active for the next run
    } else { # Unix systems
      out <- mclapply(names(plts), FUN = gmHelper1, plts, db, grpBy, aGrpBy, byPlot, mc.cores = nCores)
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

      ## Modify some names if a different state variable was given
      names(tOut) <- str_replace(names(tOut), 'TPA', paste(stateVar, 'ACRE', sep = '_'))

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

    ## Splitting up by ESTN_UNIT
    popState <- split(pops, as.factor(pops$STATECD))

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
        out <- parLapply(cl, X = names(popState), fun = gmHelper2, popState, a, t, grpBy, aGrpBy, method)
        stopCluster(cl)
      } else { # Unix systems
        out <- mclapply(names(popState), FUN = gmHelper2, popState, a, t, grpBy, aGrpBy, method, mc.cores = nCores)
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
            summarize(l = 1-first(lambda),
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
            summarize(l = 1-first(lambda),
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
        mutate_at(vars(tEst:hEst), ~(.*wgt)) %>%
        mutate_at(vars(tVar:cvEst_hp), ~(.*(wgt^2))) %>%
        group_by(ESTN_UNIT_CN, .dots = grpBy) %>%
        summarize_at(vars(tEst:plotIn_h), sum, na.rm = TRUE)

    }

    out <- list(tEst = tEst, aEst = aEst, grpBy = grpBy, aGrpBy = aGrpBy, grpByOrig = grpByOrig)

  }

  return(out)
}



#' @export
growMort <- function(db,
                     grpBy = NULL,
                     polys = NULL,
                     returnSpatial = FALSE,
                     bySpecies = FALSE,
                     bySizeClass = FALSE,
                     landType = 'forest',
                     treeType = 'all',
                     method = 'TI',
                     lambda = .5,
                     stateVar = 'TPA',
                     treeDomain = NULL,
                     areaDomain = NULL,
                     totals = FALSE,
                     variance = FALSE,
                     byPlot = FALSE,
                     nCores = 1) {

  ##  don't have to change original code
  grpBy_quo <- enquo(grpBy)
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
  out <- lapply(X = iter, FUN = growMortStarter, db,
                grpBy_quo, polys, returnSpatial,
                bySpecies, bySizeClass,
                landType, treeType, method,
                lambda, stateVar, treeDomain, areaDomain,
                totals, byPlot, nCores, remote)
  ## Bring the results back
  out <- unlist(out, recursive = FALSE)
  aEst <- bind_rows(out[names(out) == 'aEst'])
  tEst <- bind_rows(out[names(out) == 'tEst'])
  grpBy <- out[names(out) == 'grpBy'][[1]]
  aGrpBy <- out[names(out) == 'aGrpBy'][[1]]
  grpByOrig <- out[names(out) == 'grpByOrig'][[1]]



  if (byPlot){
    tOut <- tEst

    ## Population estimates
  } else {

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
      summarize_all(sum,na.rm = TRUE) #%>%
    #mutate()
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
        mutate(TREE_TOTAL = tEst,
               RECR_TOTAL = rEst,
               MORT_TOTAL = mEst,
               REMV_TOTAL = hEst,
               AREA_TOTAL = aEst,
               RECR_TPA = RECR_TOTAL / AREA_TOTAL,
               MORT_TPA = MORT_TOTAL / AREA_TOTAL,
               REMV_TPA = REMV_TOTAL / AREA_TOTAL,
               RECR_PERC = RECR_TOTAL / TREE_TOTAL * 100,
               MORT_PERC = MORT_TOTAL / TREE_TOTAL * 100,
               REMV_PERC = REMV_TOTAL / TREE_TOTAL * 100,
               ## Ratio Var
               raVar = (1/AREA_TOTAL^2) * (rVar + (RECR_TPA^2 * aVar) - 2 * RECR_TPA * cvEst_r),
               maVar = (1/AREA_TOTAL^2) * (mVar + (MORT_TPA^2 * aVar) - 2 * MORT_TPA * cvEst_m),
               haVar = (1/AREA_TOTAL^2) * (hVar + (REMV_TPA^2 * aVar) - 2 * REMV_TPA * cvEst_h),
               rpVar = (1/TREE_TOTAL^2) * (rVar + (RECR_PERC^2 * tVar) - 2 * RECR_PERC * cvEst_rp),
               mpVar = (1/TREE_TOTAL^2) * (mVar + (MORT_PERC^2 * tVar) - 2 * MORT_PERC * cvEst_mp),
               hpVar = (1/TREE_TOTAL^2) * (hVar + (REMV_PERC^2 * tVar) - 2 * REMV_PERC * cvEst_hp),
               ## SE RATIO
               RECR_TPA_SE = sqrt(raVar) / RECR_TPA * 100,
               MORT_TPA_SE = sqrt(maVar) / MORT_TPA * 100,
               REMV_TPA_SE = sqrt(haVar) / REMV_TPA * 100,
               RECR_PERC_SE = sqrt(rpVar) / RECR_PERC * 100,
               MORT_PERC_SE = sqrt(mpVar) / MORT_PERC * 100,
               REMV_PERC_SE = sqrt(hpVar) / REMV_PERC * 100,
               ## Var ratio
               RECR_TPA_VAR = raVar,
               MORT_TPA_VAR = maVar,
               REMV_TPA_VAR = haVar,
               RECR_PERC_VAR = rpVar,
               MORT_PERC_VAR = mpVar,
               REMV_PERC_VAR = hpVar,
               ## SE TOTAL
               AREA_TOTAL_SE = sqrt(aVar) / AREA_TOTAL *100,
               TREE_TOTAL_SE = sqrt(tVar) / TREE_TOTAL *100,
               RECR_TOTAL_SE = sqrt(rVar) / RECR_TOTAL *100,
               MORT_TOTAL_SE = sqrt(mVar) / MORT_TOTAL *100,
               REMV_TOTAL_SE = sqrt(hVar) / REMV_TOTAL *100,
               ## VAR TOTAL
               AREA_TOTAL_VAR = aVar,
               TREE_TOTAL_VAR = tVar,
               RECR_TOTAL_VAR = rVar,
               MORT_TOTAL_VAR = mVar,
               REMV_TOTAL_VAR = hVar,
               ## nPlots
               # Non-zero plots
               nPlots_TREE = plotIn_t,
               nPlots_RECR = plotIn_r,
               nPlots_MORT = plotIn_m,
               nPlots_REMV = plotIn_h,
               nPlots_AREA = plotIn_AREA)
    })

    # Make some columns go away
    if (totals) {
      if (variance){
        tOut <- tOut %>%
          select(grpBy, RECR_TPA, MORT_TPA, REMV_TPA, RECR_PERC, MORT_PERC, REMV_PERC,
                 TREE_TOTAL, RECR_TOTAL, MORT_TOTAL, REMV_TOTAL, AREA_TOTAL,
                 RECR_TPA_VAR, MORT_TPA_VAR, REMV_TPA_VAR, RECR_PERC_VAR, MORT_PERC_VAR, REMV_PERC_VAR,
                 TREE_TOTAL_VAR, RECR_TOTAL_VAR, MORT_TOTAL_VAR, REMV_TOTAL_VAR, AREA_TOTAL_VAR,
                 nPlots_TREE, nPlots_RECR, nPlots_MORT, nPlots_REMV, nPlots_AREA, N)
      } else {
        tOut <- tOut %>%
          select(grpBy, RECR_TPA, MORT_TPA, REMV_TPA, RECR_PERC, MORT_PERC, REMV_PERC,
                 TREE_TOTAL, RECR_TOTAL, MORT_TOTAL, REMV_TOTAL, AREA_TOTAL,
                 RECR_TPA_SE, MORT_TPA_SE, REMV_TPA_SE, RECR_PERC_SE, MORT_PERC_SE, REMV_PERC_SE,
                 TREE_TOTAL_SE, RECR_TOTAL_SE, MORT_TOTAL_SE, REMV_TOTAL_SE, AREA_TOTAL_SE,
                 nPlots_TREE, nPlots_RECR, nPlots_MORT, nPlots_REMV, nPlots_AREA)
      }

    } else {
      if (variance){
        tOut <- tOut %>%
          select(grpBy, RECR_TPA, MORT_TPA, REMV_TPA, RECR_PERC, MORT_PERC, REMV_PERC,
                 RECR_TPA_VAR, MORT_TPA_VAR, REMV_TPA_VAR, RECR_PERC_VAR, MORT_PERC_VAR, REMV_PERC_VAR,
                 nPlots_TREE, nPlots_RECR, nPlots_MORT, nPlots_REMV,nPlots_AREA, N)
      } else {
        tOut <- tOut %>%
          select(grpBy, RECR_TPA, MORT_TPA, REMV_TPA, RECR_PERC, MORT_PERC, REMV_PERC,
                 RECR_TPA_SE, MORT_TPA_SE, REMV_TPA_SE, RECR_PERC_SE, MORT_PERC_SE, REMV_PERC_SE,
                 nPlots_TREE, nPlots_RECR, nPlots_MORT, nPlots_REMV,nPlots_AREA)
      }

    }

    # Snag the names
    tNames <- names(tOut)[names(tOut) %in% grpBy == FALSE]
    ## Modify some names if a different state variable was given
    #names(tOut) <- str_replace(names(tOut), 'TPA', paste(stateVar, 'ACRE', sep = '_'))

  }

  ## Modify some names if a different state variable was given
  if (stateVar != 'TPA') names(tOut) <- str_replace(names(tOut), 'TPA', paste(stateVar, 'ACRE', sep = '_'))

  # Snag the names
  tNames <- names(tOut)[names(tOut) %in% grpBy == FALSE]
  ## Modify some names if a different state variable was given
  #names(tOut) <- str_replace(names(tOut), 'TPA', paste(stateVar, 'ACRE', sep = '_'))

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
      tOut <- left_join(tOut, polys, by = 'polyID') %>%
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
