#Written by Andre Andrade
BandsPartition_TMLA <- function(evnVariables,
                                RecordsData,
                                N,
                                pseudoabsencesMethod = PabM,
                                PrAbRatio = PabR,
                                DirSave = DirB,
                                DirM=DirM,
                                MRst=sp_accessible_area,
                                type=TipoMoran){

  #Parameters
    #evnVariables: Predictors
    #RecordsData: Occurrence List
    #N: Longitudinal(1) or Latitudinal(2) bands
  KM <- function(cell_coord, variable, NumAbsence) {
    # cell_env = cell environmental data
    # variable = a stack raster with variables
    # NumAbsence = number of centroids sellected as absences
    # This function will be return a list whith the centroids sellected
    # for the clusters
    var <- extract(variable, cell_coord)
    Km <- kmeans(cbind(cell_coord, var), centers = NumAbsence)
    ppa2 <- (list(
      Centroids = Km$centers[, 1:2],
      Clusters = Km$cluster
    ))
    
    abse <- ppa2$Centroids
    colnames(abse) <- c("lon", "lat")
    
    ppaNA <- extract(variable[[1]], abse)
    
    if (sum(is.na(ppaNA)) != 0) {
      ppaNA1 <- which(is.na(ppaNA))
      # Wich pseudo absence is a environmental NA
      ppaNA2 <- as.data.frame(cbind(ppa2$Clusters, rasterToPoints(variable[[1]])[,-3]))
      ppa.clustres <- split(ppaNA2[, 2:3], ppaNA2[, 1])
      ppa.clustres <- ppa.clustres[ppaNA1]
      nearest.point <- list()
      
      if (length(ppaNA1) < 2) {
        error <- matrix(abse[ppaNA1,], 1)
        colnames(error) <- colnames(abse)
      } else{
        error <- abse[ppaNA1,]
      }
      
      nearest.point <- list()
      for (eee in 1:length(ppaNA1)) {
        x <- flexclust::dist2(ppa.clustres[[eee]], error, method = "euclidean", p = 2)
        x <- as.data.frame(x)
        nearest.point[[eee]] <-
          as.data.frame(ppa.clustres[[eee]][which.min(x[, eee]),])
      }
      nearest.point <- t(matrix(unlist(nearest.point), 2))
      abse[ppaNA1,] <- nearest.point
    }
    return(abse)
  }
  
  # Inverse bioclim
  inv_bio <- function(e, p){
    Model <- dismo::bioclim(e, p)
    r <- dismo::predict(Model, e)
    names(r) <- "Group"
    r <- round(r, 5)
    r <- (r - minValue(r)) /
      (maxValue(r) - minValue(r))
    r <-(1-r)>=0.99 #environmental constrain
    r[which(r[,]==FALSE)] <- NA
    return(r)
  }
  
  # Inverse geo
  inv_geo <- function(e, p, d){
    Model <- dismo::circles(p, lonlat=T, d=d)
    r <- mask(e[[1]], Model@polygons, inverse=T)
    names(r) <- "Group"
    r[is.na(r)==F] <- 1 
    r[which(r[,]==FALSE)] <- NA
    return(r)
  }
  #Development
  #Start Cluster
  cl <- makeCluster(detectCores() - 1)
  registerDoParallel(cl)
  

  #Separate data by groups
  RecordsData <- lapply(RecordsData, function(x) cbind(x,rep(0,nrow(x))))
  colnames <- c("x","y","Seg")
  RecordsData <- lapply(RecordsData, setNames, colnames)
  RecordsData <- lapply(RecordsData, function(x) round(x, digits=5))
  
  grid <- seq(2,20,2)
  
  #Start species loop----
  results <- foreach(
    x = 1:length(RecordsData),
    .packages = c("raster", "modEvA", "ape", "dismo", "plyr"),
    .export = c("Moran_for_Quadrants_Pair_TMLA", 'Geo_Buf')
    ) %dopar% {
    # for(x in 1:length(RecordsData)){
    opt <- NULL
    print(names(RecordsData)[x])
    RecordsData.s <- RecordsData[[x]]

    for (quad in seq(2,20,2)){
      
      RecordsData.st <- RecordsData.s
      print(paste(quad, "Quadrants", sep=" "))
      
      #Bands----
      for (segm in 1:quad){
        axfin <- min(RecordsData.st[,N])+((max(RecordsData.st[,N])-min(RecordsData.st[,N]))/quad)*segm
        axin <- min(RecordsData.st[,N])+((max(RecordsData.st[,N])-min(RecordsData.st[,N]))/quad)*(segm-1)
        
        RecordsData.st[RecordsData.st[,N]>=axin & RecordsData.st[,N]<=axfin, "Seg"] <- segm
      }
    
      RecordsData.st <- cbind(RecordsData.st,ifelse((RecordsData.st$Seg/2)%%1,1,2))
      colnames(RecordsData.st) <- c("x","y","Seg","Partition")
  
      #Moran's I----
      Moran<-Moran_for_Quadrants_Pair_TMLA(occ=RecordsData.st,pc1=evnVariables[[1]],
                                           quad=quad,type=type)
      Moran <- data.frame(cbind(quad, Moran))
        
      #MESS----
      RecordsData_e <- cbind(RecordsData.st,extract(evnVariables, RecordsData.st[,1:2]))
      RecordsData_e <- split(RecordsData_e, f=RecordsData_e$Partition)
    
      mess <- MESS(RecordsData_e[[1]][,-c(1:4)], RecordsData_e[[2]][,-c(1:4)])
      mess <- mean(mess$TOTAL, na.rm = TRUE)
      
      #SD of number of records per Band----
      pa <- RecordsData.st$Partition # Vector wiht presences and absences
      Sd <- sd(table(pa)) /
          mean(table(pa))
        
      #Combine calculations in a data frame
      res.t<-data.frame(cbind(Moran,mess,Sd))
      colnames(res.t) <- c("Partition","Moran","MESS","SD")
      opt <- rbind(opt,res.t)
    }
    names(opt) <- names(res.t)
    
    # SELLECTION OF THE BEST NUMBER OF BANDS----
    Opt2 <- opt
    Dup <- !duplicated(Opt2[c("Moran","MESS","SD")])
    Opt2 <- Opt2[Dup,]
    
    while (nrow(Opt2) > 1) {
      # I MORAN
      if (nrow(Opt2) == 1) break
      Opt2 <- Opt2[which(Opt2$Moran <= summary(Opt2$Moran)[2]),]
      if (nrow(Opt2) == 1) break
      # MESS
      Opt2 <- Opt2[which(Opt2$MESS >= summary(Opt2$MESS)[5]),]
      if (nrow(Opt2) == 1) break
      # SD
       Opt2 <- Opt2[which(Opt2$Sd <= summary(Opt2$Sd)[2]),]
       
       if(nrow(Opt2)==2) break
       
       if(unique(Opt2$Imoran.Grid.P) && unique(Opt2$Mess.Grid.P) && unique(Opt2$Sd.Grid.P)){
         Opt2 <- Opt2[nrow(Opt2),]
       }
    }
    
    if(nrow(Opt2)>1){
      Opt2 <- Opt2[nrow(Opt2),]
    }
    
    resOpt <- cbind(names(RecordsData)[x],Opt2)

    #Create Bands Mask
    
      msk<-evnVariables[[1]]
      msk[!is.na(msk[,])] <- 0

      quad <- Opt2$Partition
        
      for (segm in 1:quad){
        # axfin <- min(RecordsData.s[,N])+((max(RecordsData.s[,N])-min(RecordsData.s[,N]))/quad)*segm
        # axin <- min(RecordsData.s[,N])+((max(RecordsData.s[,N])-min(RecordsData.s[,N]))/quad)*(segm-1)
        # RecordsData.s[RecordsData.s[,N]>=axin & RecordsData.s[,N]<=axfin, "Seg"] <- segm
        if(N%in%1){
          ex <- extent(msk)
          axfin <- ex[1]+((ex[2]-ex[1])/quad)*segm
          axin <- ex[1]+((ex[2]-ex[1])/quad)*(segm-1)
          RecordsData.s[RecordsData.s[,N]>=axin & RecordsData.s[,N]<=axfin, "Seg"] <- segm
          if (((segm/2)-round(segm/2))!=0){
            y1<-ncol(msk)-floor((axfin-msk@extent[1])/xres(msk))
            y0<-ncol(msk)-floor((axin-msk@extent[1])/xres(msk))
            for (y in y1:y0){
              msk[,y] <- 1;
            }
            msk[][is.na(evnVariables[[1]][])]<-NA
          }else{
            y1<-ncol(msk)-floor((axfin-msk@extent[1])/xres(msk))
            y0<-ncol(msk)-floor((axin-msk@extent[1])/xres(msk))
            
            for (y in y1:y0){
              msk[,y] <- 2;
            }
            msk[][is.na(evnVariables[[1]][])]<-NA
          }
        }
        
        if(N%in%2){
          ex <- extent(msk)
          axfin <- ex[3]+((ex[4]-ex[3])/quad)*segm
          axin <- ex[3]+((ex[4]-ex[3])/quad)*(segm-1)
          RecordsData.s[RecordsData.s[,N]>=axin & RecordsData.s[,N]<=axfin, "Seg"] <- segm
          if (((segm/2)-round(segm/2))!=0){
            y1<-nrow(msk)-floor((axfin-msk@extent[3])/yres(msk))
            y0<-nrow(msk)-floor((axin-msk@extent[3])/yres(msk))
          
            for (y in y1:y0){
              msk[y,] <- 1;
            }
            msk[][is.na(evnVariables[[1]][])]<-NA

          }else{
            y1<-nrow(msk)-floor((axfin-msk@extent[3])/yres(msk))
            y0<-nrow(msk)-floor((axin-msk@extent[3])/yres(msk))
          
            for (y in y1:y0){
              msk[y,] <- 2;
            }
            msk[][is.na(evnVariables[[1]][])]<-NA
          }
        }
      }

      RecordsData.s <-
        cbind(RecordsData.s, ifelse((RecordsData.s$Seg / 2) %% 1, 1, 2))
      RecordsData.s <-
        cbind(rep(names(RecordsData)[x], nrow(RecordsData.s)), RecordsData.s)
      colnames(RecordsData.s) <- c("sp","x","y","Seg","Partition")
      RecordsData.s <- RecordsData.s[,c("sp","x","y","Partition")]
      RecordsData.s <- cbind(RecordsData.s, rep(1,nrow(RecordsData.s)))
      colnames(RecordsData.s) <- c("sp","x","y","Partition","PresAbse")
      msk[msk[]==0] <-  NA      #ASC with the ODD-EVEN quadrants
      writeRaster(msk, paste(DirSave,paste(names(RecordsData)[x],".tif",sep=""), sep="\\"),
                  format="GTiff",NAflag = -9999,overwrite=T)
      
############################################################
#                                                          #
#              Pseudoabsences allocation-----              #####
#                                                          #
############################################################

      # Pseudo-Absences with Random allocation-----
      if(pseudoabsencesMethod=="RND"){
        # Clip the mask raster to generate rando pseudoabsences
        pseudo.mask <- msk
        pseudo.mask2 <- list()

        for(i in 1:2){
          mask3 <- pseudo.mask
          mask3[!mask3[]==i] <- NA 
          pseudo.mask2[[i]] <- mask3
        }
        
        pseudo.mask <- brick(pseudo.mask2)
        rm(pseudo.mask2)
        # Random allocation of pseudoabsences 
        absences <- list()
        for (i in 1:2) {
          set.seed(x)
          if(MRst=="Y"){
            SpMask <- raster(file.path(DirM,paste0(names(RecordsData)[x],".tif")))
            pseudo.mask[[i]] <- pseudo.mask[[i]]*SpMask
            if(sum(is.na(SpMask[])==F)<(PrAbRatio*nrow(RecordsData[[x]]))){
              warning("The ammount of cells in the M restriction is insuficient to generate a 1:1 number of pseudo-absences") 
              stop("Please try again with another restriction type or without restricting the extent")
            }
          }
          absences.0 <- randomPoints(pseudo.mask[[i]], (1 / PrAbRatio)*sum(RecordsData.s[,"Partition"]==i),
                                     ext = extent(pseudo.mask[[i]]),
                                     prob = FALSE)
          colnames(absences.0) <- c(x, y)
          absences[[i]] <- as.data.frame(absences.0)
          rm(absences.0)
        }
        for (i in 1:length(absences)){
          absences[[i]] <- cbind(absences[[i]], rep(i,nrow(absences[[i]])))  
        }
        absences <- lapply(absences, function(x) cbind(x, rep(0,nrow(x))))
        absences <- lapply(absences, function(y) cbind(rep(names(RecordsData)[x],nrow(y)),y))
        absences <- ldply(absences, data.frame)
        colnames(absences) <- colnames(RecordsData.s)
      }
      
      # Pseudo-Absences allocation with Environmental constrain ----
      if(pseudoabsencesMethod=="ENV_CONST"){

        pseudo.mask <- inv_bio(e = evnVariables, p =RecordsData.s[,c("x","y")])
        
        # Split the raster of environmental layer with grids
        pseudo.mask <- pseudo.mask*msk 
        pseudo.mask2 <- list()

        for(i in 1:2){
          mask3 <- pseudo.mask
          mask3[!msk[]==i] <- NA 
          mask3[is.na(msk[])] <- NA 
          pseudo.mask2[[i]] <- mask3
        }
        pseudo.mask <- brick(pseudo.mask2)
        rm(pseudo.mask2)
        
        absences <- list()
        for (i in 1:2) {
          set.seed(x)
          if(MRst=="Y"){
            SpMask <- raster(file.path(DirM,paste0(names(RecordsData)[x],".tif")))
            pseudo.mask[[i]] <- pseudo.mask[[i]]*SpMask
            if(sum(is.na(SpMask[])==F)<(PrAbRatio*nrow(RecordsData[[x]]))){
              warning("The ammount of cells in the M restriction is insuficient to generate a 1:1 number of pseudo-absences") 
              stop("Please try again with another restriction type or without restricting the extent")
            }
          }
          absences.0 <- randomPoints(pseudo.mask[[i]], (1 / PrAbRatio)*sum(RecordsData.s[,"Partition"]==i),
                                     ext = extent(pseudo.mask[[i]]),
                                     prob = FALSE)
          colnames(absences.0) <- c(x, y)
          absences[[i]] <- as.data.frame(absences.0)
          rm(absences.0)
        }
        for (i in 1:length(absences)){
          absences[[i]] <- cbind(absences[[i]], rep(i,nrow(absences[[i]])))  
        }
        absences <- lapply(absences, function(x) cbind(x, rep(0,nrow(x))))
        absences <- lapply(absences, function(y) cbind(rep(names(RecordsData)[x],nrow(y)),y))
        absences <- ldply(absences, data.frame)
        colnames(absences) <- colnames(RecordsData.s)
      }
      
      # Pseudo-Absences allocation with Geographical constrain-----
      if(pseudoabsencesMethod=="GEO_CONST"){
        
        pseudo.mask <- inv_geo(e=evnVariables[[1]], p=RecordsData.s[,c("x","y")], d=Geo_Buf)
        
        # Split the raster of environmental layer with grids
        pseudo.mask <- pseudo.mask*msk 
        pseudo.mask2 <- list()
        
        for(i in 1:2){
          mask3 <- pseudo.mask
          mask3[!msk[]==i] <- NA 
          mask3[is.na(msk[])] <- NA 
          pseudo.mask2[[i]] <- mask3
        }
        pseudo.mask <- brick(pseudo.mask2)
        rm(pseudo.mask2)
        
        absences <- list()
        for (i in 1:2) {
          set.seed(x)
          if(MRst=="Y"){
            SpMask <- raster(file.path(DirM,paste0(names(RecordsData)[x],".tif")))
            pseudo.mask[[i]] <- pseudo.mask[[i]]*SpMask
            if(sum(is.na(SpMask[])==F)<(PrAbRatio*nrow(RecordsData[[x]]))){
              warning("The ammount of cells in the M restriction is insuficient to generate a 1:1 number of pseudo-absences") 
              stop("Please try again with a smaller geographical buffer or without restricting the accessible area")
            }
          }
          absences.0 <- randomPoints(pseudo.mask[[i]], (1 / PrAbRatio)*sum(RecordsData.s[,"Partition"]==i),
                                     ext = extent(pseudo.mask[[i]]),
                                     prob = FALSE)
          colnames(absences.0) <- c(x, y)
          absences[[i]] <- as.data.frame(absences.0)
          rm(absences.0)
        }
        for (i in 1:length(absences)){
          absences[[i]] <- cbind(absences[[i]], rep(i,nrow(absences[[i]])))  
        }
        absences <- lapply(absences, function(x) cbind(x, rep(0,nrow(x))))
        absences <- lapply(absences, function(y) cbind(rep(names(RecordsData)[x],nrow(y)),y))
        absences <- ldply(absences, data.frame)
        colnames(absences) <- colnames(RecordsData.s)
      }
      
      # Pseudo-Absences allocation with Environmentla and Geographical  constrain-----
      if(pseudoabsencesMethod=="GEO_ENV_CONST"){
        
        pseudo.mask <- inv_geo(e=evnVariables[[1]], p=RecordsData.s[,c("x","y")], d=Geo_Buf)
        pseudo.mask2 <- inv_bio(e = evnVariables, p = RecordsData.s[, c("x", "y")])
        pseudo.mask <- pseudo.mask*pseudo.mask2

        # Split the raster of environmental layer with grids
        pseudo.mask <- pseudo.mask*msk 
        pseudo.mask2 <- list()
        
        for(i in 1:2) {
          mask3 <- pseudo.mask
          mask3[!msk[] == i] <- NA
          mask3[is.na(msk[])] <- NA
          pseudo.mask2[[i]] <- mask3
        }
        pseudo.mask <- brick(pseudo.mask2)
        rm(pseudo.mask2)
        
        absences <- list()
        for (i in 1:2) {
          set.seed(x)
          if(MRst=="Y"){
            SpMask <- raster(file.path(DirM,paste0(names(RecordsData)[x],".tif")))
            pseudo.mask[[i]] <- pseudo.mask[[i]]*SpMask
            if(sum(is.na(SpMask[])==F)<(PrAbRatio*nrow(RecordsData[[x]]))){
              warning("The ammount of cells in the M restriction is insuficient to generate a 1:1 number of pseudo-absences") 
              stop("Please try again with a smaller geographical buffer or without restricting the accessible area")
            }
          }
          absences.0 <- randomPoints(pseudo.mask[[i]], (1 / PrAbRatio)*sum(RecordsData.s[,"Partition"]==i),
                                     ext = extent(pseudo.mask[[i]]),
                                     prob = FALSE)
          colnames(absences.0) <- c(x, y)
          absences[[i]] <- as.data.frame(absences.0)
          rm(absences.0)
        }
        for (i in 1:length(absences)){
          absences[[i]] <- cbind(absences[[i]], rep(i,nrow(absences[[i]])))  
        }
        absences <- lapply(absences, function(x) cbind(x, rep(0,nrow(x))))
        absences <- lapply(absences, function(y) cbind(rep(names(RecordsData)[x],nrow(y)),y))
        absences <- ldply(absences, data.frame)
        colnames(absences) <- colnames(RecordsData.s)
      }
      
      # Pseudo-Absences allocation with Environmentla and Geographical and k-mean constrain-----
      if(pseudoabsencesMethod=="GEO_ENV_KM_CONST"){
        
        pseudo.mask <- inv_geo(
          e=evnVariables[[1]],
          p=RecordsData.s[,c("x","y")],
          d=Geo_Buf)
        
        pseudo.mask2 <- inv_bio(
          e = evnVariables, 
          p = RecordsData.s[, c("x", "y")])
        
        pseudo.mask <- pseudo.mask*pseudo.mask2
        
        # Split the raster of environmental layer with grids
        pseudo.mask <- pseudo.mask*msk 
        pseudo.mask2 <- list()
        
        for(i in 1:2){
          mask3 <- pseudo.mask
          mask3[!msk[]==i] <- NA 
          mask3[is.na(msk[])] <- NA 
          pseudo.mask2[[i]] <- mask3
        }
        pseudo.mask <- brick(pseudo.mask2)
        rm(pseudo.mask2)
        
        absences <- list()
        for (i in 1:2) {
          set.seed(x)
          if(MRst=="Y"){
            SpMask <- raster(file.path(DirM,paste0(names(RecordsData)[x],".tif")))
            pseudo.mask[[i]] <- pseudo.mask[[i]]*SpMask
            if(sum(is.na(SpMask[])==F)<(PrAbRatio*nrow(RecordsData[[x]]))){
              warning("The ammount of cells in the M restriction is insuficient to generate a 1:1 number of pseudo-absences") 
              stop("Please try again with a smaller geographical buffer or without restricting the accessible area")
            }
          }
          
          absences.0 <- KM(rasterToPoints(pseudo.mask[[i]])[,-3],
                           mask(evnVariables, pseudo.mask[[i]]),
                           (1 / PrAbRatio)*sum(RecordsData.s[,'Partition']==i))
          # ppa2 <-
          #   KM(rasterToPoints(pseudo.mask[[i]])[,-3],
          #      mask(evnVariables, pseudo.mask[[i]]),
          #      (1 / PrAbRatio)*sum(RecordsData.s[,'Partition']==i))
          # absences.0 <- ppa2$Centroids
          # colnames(absences.0) <- c("lon", "lat")
          # 
          # ppaNA <- extract(pseudo.mask[[i]], absences.0)
          # 
          # if (sum(is.na(ppaNA)) != 0) {
          #   ppaNA1 <- which(is.na(ppaNA))
          #   # Wich pseudo absence is a environmental NA
          #   ppaNA2 <- as.data.frame(cbind(ppa2$Clusters, rasterToPoints(pseudo.mask[[i]])[,-3]))
          #   ppa.clustres <- split(ppaNA2[, 2:3], ppaNA2[, 1])
          #   ppa.clustres <- ppa.clustres[ppaNA1]
          #   nearest.point <- list()
          #   
          #   if (length(ppaNA1) < 2) {
          #     error <- matrix(absences.0[ppaNA1,], 1)
          #     colnames(error) <- colnames(absences.0)
          #   } else{
          #     error <- absences.0[ppaNA1,]
          #   }
          #   
          #   nearest.point <- list()
          #   for (eee in 1:length(ppaNA1)) {
          #     xcl <- flexclust::dist2(ppa.clustres[[eee]], error, method = "euclidean", p = 2)
          #     xcl <- as.data.frame(xcl)
          #     nearest.point[[eee]] <-
          #       as.data.frame(ppa.clustres[[eee]][which.min(xcl[, eee]),])
          #   }
          #   nearest.point <- t(matrix(unlist(nearest.point), 2))
          #   absences.0[ppaNA1,] <- nearest.point
          # }
          
          absences[[i]] <- as.data.frame(absences.0)
          rm(absences.0)
        }
        
        for (i in 1:length(absences)){
          absences[[i]] <- cbind(absences[[i]], rep(i,nrow(absences[[i]])))  
        }
        
        absences <- lapply(absences, function(x) cbind(x, rep(0,nrow(x))))
        absences <-
          lapply(absences, function(y) cbind(rep(names(RecordsData)[x],nrow(y)),y))
        absences <- ldply(absences, data.frame)
        colnames(absences) <- colnames(RecordsData.s)
      }
      
      RecordsData.s <- rbind(RecordsData.s, absences)
      
      #Final Data Frame Results
      out <- list(ResultList= RecordsData.s,
                  ResOptm = resOpt)
      return(out)
  }
  
  FinalResult <- data.frame(data.table::rbindlist(do.call(c,lapply(results, "[", "ResultList"))))
  FinalInfoGrid <- data.frame(data.table::rbindlist(do.call(c,lapply(results, "[", "ResOptm"))))
  
  write.table(FinalInfoGrid,paste(DirSave,"Band_Moran_MESS.txt",sep="\\"),sep="\t",row.names=F)
  write.table(FinalResult,paste(DirSave,"OccBands.txt",sep="\\"),sep="\t",row.names=F)
  stopCluster(cl)
  return(FinalResult) ########### nao seria return(FinalResult)
}

