#=======================================================================================
# Sparse matrix recommender framework in R
# Copyright (C) 2014  Anton Antonov
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# 
# Written by Anton Antonov, 
# antononcube@gmail.com, 
# 7320 Colbury Ave, 
# Windermere, Florida, USA.
#
#=======================================================================================

#=======================================================================================
# Initially this code was made to resemble the Sparse Matrix Recommender Mathematica 
# package [1] as closely as possible, but an approach more inherent to R was taken. 
# Namely, the columns and the rows of the metadata matrix are named, and because of this 
# tag-index and item-index rules are not required.

# The tag-index and item-index rules are made with integer arrays with named entries.

# I did consider programming and using a S4 object, but that requires the declaration of 
# too many generic functions. And because inheritance is not essential I kept the object 
# in a list.

# There should be separate files (packages) for term weights and outlier detection.
# See the notes below. 

# [1] Anton Antonov, Sparse matrix recommender framework in Mathematica, 
#     SparseMatrixRecommenderFramework.m at MathematicaForPrediction project at GitHub, (2014).
#     URL: https://github.com/antononcube/MathematicaForPrediction/blob/master/SparseMatrixRecommenderFramework.m
# 
# History
# Started: November 2013, 
# Updated: December 2013, May 2014, June 2014, July 2014, December 2014
#=======================================================================================
#
# TODO Argument type and ranks check
# Mathematica has pattern matching for the arguments, here I have to make type checks.
# Note that S4 provides some of this functionality.

#---------------------------------------------------------------------------------------

# 05/02/14
# I am not sure:
# 1. should the recommendation request functions take data frames,
# 2. should the scores be the first column (as in the Mathematica code).
# These points need more design effort.

# 05/12/14
# After a conversation with a coworker: it is better instead of an array for tag type
# offsets to use a data frame with the column ranges of the tag types.

# 07/30/14
# 1. Refactored the code for creation of SMR objects: two signatures from transactions,
# and from matrices.
# 2. Extracted the document-term weight functions in a separate file:
# DocumentTermWeightFunctions.R
#
# 12/23/14
# Added the function SMRReorderRecommendations that re-orders recommendations according
# to scores from common tags.
#=======================================================================================

#' @detail Required libraries
require(plyr)
require(reshape2)
require(Matrix)

#' @deatil Read weight functions application definitions
# source("./DocumentTermWeightFunctions.R")
 
#' @description Convert to contingency matrix from item consumption "transactions" (e.g. instances of movie watching)
#' @param dataRows a data frame corresponding to a item consumption metadata table
#' @param itemColumnName name of the column of dataRows the values of which correspond to the rows of the returned matrix
#' @param tagType name of the column of dataRows the values of which correspond to the columns of the returned matrix
#' @param sparse a logical, should the returned matrix be sparse or not
#' @return a matrix 
SMRCreateItemTagMatrix <- function( dataRows, itemColumnName, tagType, sparse=TRUE ) {
  frequencies <- count(dataRows, vars=c(itemColumnName, tagType))
  formulaString <- paste("freq ~", itemColumnName, "+", tagType)
  xtabs(as.formula(formulaString), frequencies, sparse=sparse )  
}

#' @description Creates a sparse matrix recommender from transactions data and a list of tag types
#' @param dataRows transaction data frame
#' @param tagTypes the name of the column containing the categorical tags
#' @param itemColumnName the name of the column containing the unique items
SMRCreate <- function(dataRows, tagTypes, itemColumnName ){
  matrices <- alply(tagTypes, 1, function(x){
    SMRCreateItemTagMatrix(dataRows, tagType=x, itemColumnName=itemColumnName)
  })
  
  SMRCreateFromMatrices(matrices, tagTypes, itemColumnName)
}

#' @description Creates a sparse matrix recommender from a list of matrices and a corresponding list of tag types
#' @param matrices matrices to be spliced into a metadata matrix
#' @param tagTypes the name of the column containing the categorical tags
#' @param itemColumnName the name of the column containing the unique items
SMRCreateFromMatrices <- function( matrices, tagTypes, itemColumnName ){
  
  if ( length(matrices) != length(tagTypes)  ) {
    stop("The same number of matrices and tag types is required.", call.=TRUE)
  }
  
  m <- do.call(cBind, matrices)
  
  widths <- laply(matrices, function(x){ncol(x)})
  ends = cumsum(widths)
  begins = ends - widths + 1
  ranges <- data.frame(Begin=begins, End=ends)
  rownames(ranges)=tagTypes
  
  tagToIndexRules <- 1:ncol(m)
  names(tagToIndexRules) <- colnames(m)
  
  itemToIndexRules <- 1:nrow(m)
  names(itemToIndexRules) <- rownames(m)
  
  list( M=m, M01=m, TagTypeRanges=ranges, TagTypes=tagTypes, ItemColumnName=itemColumnName, 
        TagToIndexRules=tagToIndexRules, ItemToIndexRules=itemToIndexRules )
}


#' @description Changes the weights of the tags of a sparse matrix recommender object
#' @param smr a sparse matrix recommender object (list with named elements)
#' @param weights a list of weights to be applied
SMRApplyTagWeights <- function( smr, weights ) {
  if ( length(weights) < ncol(smr$M01) ) {
    weights <- rep( weights, ncol(smr$M01) )
  } else if ( length(weights) > ncol(smr$M01) ) {
    weights <- weights[1:ncol(smr$M01)]
  }
  W <- Diagonal(x=weights)
  smr$M01 %*% W
}

#' @description Makes all sub-matrices to have elements between 0 and 1
#' @param smr a sparse matrix recommender object (list with named elements)
SMRNormalizeSubMatricesByMaxEntry <- function( smr ) {
  mWeights <- laply( smr$TagTypes, function(tt) max( SMRSubMatrix(smr, tt) ) )
  mWeights[ mWeights == 0 ] <- 1
  SMRApplyTagTypeWeights( smr, 1 / mWeights )
}

#' @description Changes the weights of tag types of a sparse matrix recommender object
#' @param smr a sparse matrix recommender object (list with named elements)
#' @param weights a list of weights to be applied
SMRApplyTagTypeWeights <- function( smr, weights ) {
  if ( length(weights) < length(smr$TagTypes) ) {
    weights <- rep(weights, length(smr$TagTypes) )
  } else if ( length(weights) > length(smr$TagTypes) ) {
    weights <- weights[1:length(smr$TagTypes)]
  }
  #wvec <- unlist(mlply(cbind(smr$TagTypeRanges,W=weights), function(Begin,End,W) rep(W,End-Begin+1)))
  wvec <- llply( 1:nrow(smr$TagTypeRanges), function(i) rep( weights[i], smr$TagTypeRanges[i,]$End - smr$TagTypeRanges[i,]$Begin + 1 ) )
  wvec <- do.call( c, wvec )
  SMRApplyTagWeights( smr, wvec )
}


#' @description Returns the sub-matrix of the SMR metadata matrix that corresponds to a tag type
#' @param smr a sparse matrix recommender object (list with named elements)
#' @param tagType a tag type
SMRSubMatrix <- function(smr, tagType ){
  smr$M[,smr$TagTypeRanges[tagType, "Begin"]:smr$TagTypeRanges[tagType, "End"]]
}

#' @description Returns the sub-matrix of a matrix that corresponds to a tag type in an SMR object
#' @param M a sparse matrix (in a sparse matrix recommender object)
#' @param ranges column ranges of sub-matrices (in a sparse matrix recommender object)
#' @param tagType a tag type
SMRSubMatrixOfMatrix <- function( M, ranges, tagType ) {
  M[,ranges[tagType, "Begin"]:ranges[tagType, "End"]]
}

#' @description Finds the current significance factors in a SMR object
#' @param smr a sparse matrix object
SMRCurrentTagTypeSignificanceFactors <- function(smr) {
  sfs01 <- laply( smr$TagTypes, function(tc) sum( SMRSubMatrixOfMatrix( smr$M01, smr$TagTypeRanges, tc ) ) )
  sfs01[ sfs01 == 0 ] <- 1
  res <- laply( smr$TagTypes, function(tc) sum( SMRSubMatrix( smr, tc ) ) ) / sfs01
  setNames( res, smr$TagTypes ) 
}


#' @description Recommend items based on a sparse matrix and user history of consumption
#' @param smr sparse matrix recommender 
#' @param userHistoryItems the items the user has consumed / purchased
#' @param userRatings ratings of the history items
#' @param nrecs number of recommendations to be returned
#' @param removeHistory should the history be removed from the recommendations
SMRRecommendations <- function( smr, userHistoryItems, userRatings, nrecs, removeHistory=TRUE ) {
  
  if ( class(userHistoryItems) != "integer" && class(userHistoryItems) != "numeric" ) {
    userHistoryItems <- match( userHistoryItems, rownames(smr$M) )
  }
  if ( class(userHistoryItems) != "integer" && class(userHistoryItems) != "numeric" ) {
    stop("Row ID's (names or indices) are expected for the argument userHistoryItems.", call.=TRUE)
  }
  if ( class(userRatings) != "numeric") {
    stop("Positive real numbers are expected for the argument userRatings.", call.=TRUE)
  }
  if ( length(userRatings) < length(userHistoryItems) ) {
    userRatings <- rep( userRatings, length(userHistoryItems) )
  }
  if ( length(userRatings) > length(userHistoryItems) ) {
    userRatings <- userRatings[1:length(userHistoryItems)]
  }
  
  hvec <- sparseMatrix(i=rep(1,length(userHistoryItems)), j=userHistoryItems, x=userRatings, dims=c(1,dim(smr$M)[1]))
  rvec <- smr$M %*% t(hvec %*% smr$M) 
  rvec <- as.array(rvec)
  recInds <- rev(order(rvec))[1:(nrecs+length(userHistoryItems))]
  
  if ( removeHistory ) {
    dropInds <- recInds %in% userHistoryItems
    recInds <- recInds[ ! dropInds ]
  }
  
  if ( nrecs < length(recInds) ) {
    recInds <- recInds[1:nrecs]
  }
  recScores <- rvec[ recInds ]
  
  res<-as.data.frame(cbind(recScores,recInds), stringsAsFactors=FALSE)
  res<-cbind(res,rownames(smr$M)[recInds], stringsAsFactors=FALSE)
  names(res)<-c("Score","Index","Item")
  res
}


#' @description Recommend items based on a sparse matrix and user history of consumption
#' @param smr sparse matrix recommender 
#' @param history a data frame of rated items with colums("Ratings",<some-item-ID>)
#' @param nrecs number of recommendations to be returned
#' @param removeHistory should the history be removed from the recommendationsa
SMRRecommendationsDF <- function( smr, history, nrecs, removeHistory ) {
  if ( is.numeric(history[,2]) ) {
    res <- SMRRecommendations( smr, history[,2], history[,1], nrecs) 
  } else {
    inds <- match(  history[,2], rownames( smr$M ) )
    if (  NA %in% inds ) {
      stop("Some of the items are not in the sparse matrix recommender object.")
    }
    res <- SMRRecommendations( smr, inds, history[,1], nrecs) 
  }
  names(res) <- c( names(res)[1:2], names(history)[[2]] )
  res
}


#' @description Recommend items based on a sparse matrix and specified profile
#' @param smr sparse matrix recommender
#' @param profileInds metadata indices corresponding to the columns of \param smr$M
#' @param profileRatings ratings of the profile metadata
#' @param nrecs number of recommendations to be returned
SMRRecommendationsByProfile <- function( smr, profileInds, profileRatings, nrecs ) {
    pvec <- sparseMatrix(i=rep(1,length(profileInds)), j=profileInds, x=profileRatings, dims=c(1,dim(smr$M)[2]))
    SMRRecommendationsByProfileVector( smr, pvec, nrecs )
}


#' @description Recommend items based on a sparse matrix and specified profile
#' @param smar sparse matrix recommender
#' @param profileVec is a sparse matrix with 1 row (a row from a sparse matrix)
#' @param nrecs number of recommendations to be returned
SMRRecommendationsByProfileVector <- function( smr, profileVec, nrecs ) {
  if ( dim( profileVec )[[2]] == dim( smr$M )[[2]] ) {
    profileVec <- t(profileVec)
  }
  rvec <- smr$M %*% profileVec 
  rvec <- as.array(rvec)
  recInds <- rev(order(rvec))
  recScores <- rvec[recInds]
  if ( nrecs > length(rvec) ) {
    nrecs <- length(rvec)
  }
  res<-as.data.frame(cbind(recScores[1:nrecs],recInds[1:nrecs]), stringsAsFactors=FALSE)
  res<-cbind(res,rownames(smr$M)[recInds[1:nrecs]], stringsAsFactors=FALSE)
  names(res)<-c( "Score", "Index", "Item" )
  res
}


#' @description Calculate profile vector from item history
#' @param smr a sparse matrix recommendation object
#' @param itemHistory a data frame with items history with column names c("Rating", "Item")
SMRProfileVector <- function( smr, itemHistory ) {
  pinds <- match( itemHistory[,2], rownames(smr$M) )
  names(itemHistory) <- c("Rating", "Item")
  hvec <- sparseMatrix( i=rep(1,nrow(itemHistory)), j=pinds, x=itemHistory$Rating, dims=c(1,dim(smr$M)[1]) )
  pvec <- hvec %*% smr$M
  t(pvec)
}


#' @description Calculate profile from item history
#' @param smr a sparse matrix recommendation object
#' @param itemHistory a data frame with item history with column names c("Rating", "Item")
SMRProfileDF <- function( smr, itemHistory ) {
  pvec <- SMRProfileVector( smr, itemHistory )
  pvecInds <- which( pvec > 0 )
  pvecScores <- pvec[ pvecInds ]
  res<-as.data.frame( cbind( pvecScores, pvecInds) )
  res<-cbind( res, colnames(smr$M)[ pvecInds ], stringsAsFactors = FALSE )
  names(res) <- c("Score","Index","Tag")
  res[ rev( order(res$Score) ),]
}


#' @description Return a data frame corresponding to a profile vector
#' @param smr a sparse matrix recommendation object
#' @param pvec a sparse matrix with one column
SMRProfileDFFromVector <- function( smr, pvec ) {
  pvecInds <- which( pvec > 0 )
  pvecScores <- pvec[ pvecInds ]
  res<-as.data.frame( cbind( pvecScores, pvecInds) )
  res<-cbind( res, colnames(smr$M)[ pvecInds ], stringsAsFactors = FALSE )
  names(res) <- c("Score","Index","Tag")
  res[ rev( order(res$Score) ), ]
}


#' @description Gives the interpetation of a data frame of recommendations with sparse matrix recommender object
#' @param smr sparse matrix recommender object
#' @param recs a data frame of recommendations with column names Score and Index
#' @parame tagTypes which tag types to use
SMRItemData <- function(smr, recs, tagTypes=NULL) {
  if ( is.null(tagTypes) ) {
    sm <- smr$M[recs$Index,]
  } else {
    sm <- smr$M[recs$Index, ]
    sms <- llply( tagTypes, function(tg) sm[,smr$TagTypeRanges[tg, "Begin"]:smr$TagTypeRanges[tg, "End"]] ) 
    sm <- do.call(cBind, sms)
  }
  pt <- as.data.frame(summary(sm))
  pt <- pt[ order(pt[,1]), ]
  pt[,1]<-rownames(sm)[pt[,1]]
  pt[,2]<-colnames(sm)[pt[,2]]
  names(pt) <- c(names(recs)[[3]], "Metadata", "Weight")
  # Now we can use split(pt, factor(pt$Item))
  unique(pt)
}


#' @description Finds the tag type of a tag
#' @param smr a sparse matrix recommender object
#' @param tag a tag (string) for which we want to find the tag type
#' @param tag type ID (string) or NULL
SMRTagType <- function( smr, tag ) {
  if ( is.numeric(tag) || is.integer(tag) ) {
    tagInd <- tag
  } else {
    if ( tag %in% colnames(smr$M) ) {
      tagInd <- which( colnames(smr$M)==tag )
    } else if ( tag %in% rownames(smr$M) ) {
      return(smr$ItemColumnName)
    } else {
      return("None")
    }
  }
  
  if ( length(tagInd) == 1 ) {
    tagTypeInd <- which( smr$TagTypeRanges$Begin <= tagInd & tagInd <= smr$TagTypeRanges$End  ) 
  } else {
    tagTypeInd <- laply( tagInd, function(x) which( smr$TagTypeRanges$Begin <= x & x <= smr$TagTypeRanges$End ) ) 
  }
  
  if ( length( tagTypeInd ) >= 1 ) {
    smr$TagTypes[ tagTypeInd ] 
  } else {
    "None"
  }
}

#' @description Re-orders a list of recommendations according to their weighted intersection with a list of tags.
#' @param smr a sparse matrix recommender object
#' @param recs a data frame recommended items, the second column being row names or row indices
#' @param tagIDs a vector tag ID's of indices with which the recommendations are scored
#' @detail The first column is expected to be of scores. The original Mathematica package function is named InterfaceUserToLoveFiltered.
SMRReorderRecommendations <- function( smr, recs, tagIDs ) {
  if ( is.character( tagIDs ) && length( tagIDs ) > 0 ) {
    ## Assuming column ID's of smr$M
    tagInds <- which( colnames(smr$M) %in% tagIDs )
  } else if ( is.numeric( tagIDs ) && length( tagIDs ) > 0 ) {
    tagInds <- tagIDs
  } else {
    stop( "The third argument, tagIDs, is expected to be a non-empty vector of column indices or column ID's.", call.=TRUE )
  }

  profileVec <- sparseMatrix( i=tagInds, j=rep(1,length(tagInds)), x=rep(1,length(tagInds)), dims = c( ncol(smr$M), 1 ) )
  
  newOrder <- smr$M[recs[[2]], ] %*% profileVec
  
  if ( sum( newOrder ) > 0 ) {
    newOrder <- rev( order( as.vector(newOrder) ) )
    recs[ newOrder, ]
  } else {
    recs
  }
}

#' @description Creates an SMR object from a given SMR object by removing specified tag types
#' @param smr a sparse matrix recommender object
#' @param removeTagTypes a list of tag types to be removed from smr
SMRRemoveTagTypes <- function( smr, removeTagTypes ) {
  
  ## Copy of the SMR
  newSMR <- smr
  
  ## There are several ways to do this:
  ## 1. Work with newSMR$TagTypeRanges, take the indices corresponding to tag types not to be removed.
  ## 2. Construct a metadata matrix by taking sub-matrices of the tag types not to be removed.
  pos <- ! ( newSMR$TagTypes %in% removeTagTypes )
  
  applySFs <- SMRCurrentTagTypeSignificanceFactors( newSMR )[pos]
  
  newSMR$M01 <-
    Reduce( function( mat, tt )
      if ( is.null(mat) ) { newSMR$M01[, newSMR$TagTypeRanges[tt,]$Begin : newSMR$TagTypeRanges[tt,]$End ] } 
      else { cBind( mat, newSMR$M01[, newSMR$TagTypeRanges[tt,]$Begin : newSMR$TagTypeRanges[tt,]$End ] ) },  
      newSMR$TagTypes[pos], NULL )
  newSMR$TagTypeRanges <- newSMR$TagTypeRanges[pos, ]
  newSMR$TagTypes <- newSMR$TagTypes[pos]
  
  newSMR$M <- SMRApplyTagTypeWeights( newSMR, applySFs )
  
  newSMR
}