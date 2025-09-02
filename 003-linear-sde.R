#------------------------------------------------------------------------------
# Author: Michael D. Hunter
# Date: 2016-05-24
# Filename: LinearSDE.R
# Purpose: An illustrative example of using dynr to fit
#   a linear stochastic differential equation model
#------------------------------------------------------------------------------


#rm(list=ls(all=TRUE))


#------------------------------------------------------------------------------
# Load packages
require(dynr)




#------------------------------------------------------------------------------
# Example 2
# Damped linear oscillator example
#	There is measurement noise and there are unmeasured dynamic disturbances.
#	These disturbances are called dynamic noise.
#	There is a single indicator.
# It is somewhat open to figure out what combination of variables can really be
#	estimated for this kind of model.  It is clear that measurement noise and
#	SOME dynamic noise can be estimated, but not all.




#------------------------------------------------------------------------------
# Define all the model components via the RECIPE functions


# measurement
# this is the factor loadings matrix, Lambda in SEM notation or C in OpenMx notation
meas <- prep.measurement(
	values.load=matrix(c(1, 0), 1, 2), # starting values and fixed values
	params.load=matrix(c('fixed', 'fixed'), 1, 2),
	state.names=c("Position","Velocity"),
	obs.names=c("y1")) # parameter numbers or indication that parameter is fixed
# Look
meas
# no free parameters in the factor loadings




# observation and dynamic noise components
# the latent noise is the dynamic noise, Psi in SEM notation or Q in OpenMx notation
# the observed noise is the measurement noise, Theta in SEM notation or R in OpenMx notation
ecov <- prep.noise(
	values.latent=diag(c(0, 1), 2), params.latent=diag(c('fixed', 'dnoise'), 2), # uses free parameter 3
	values.observed=diag(1.5, 1), params.observed=diag('mnoise', 1)) # uses free parameter 4
# Look
ecov
# dynr takes steps to make sure covariance matrices are positive definite


#ecov <- prep.noise(
#	values.latent=rep(list(diag(c(0, 1), 2)), 2), params.latent=rep(list(diag(c('fixed', 'dnoise'), 2)), 2), # uses free parameter 3
#	values.observed=list(diag(0.5, 1), diag(1.5, 1)), params.observed=list(diag('mnoise1', 1), diag('mnoise2', 1))) # uses free parameter 4




# initial covariances and latent state values
# These initialize the recursive algorithm (extended Kalman filter) that dynr uses
# These are x0 and P0 in OpenMx notation
initial <- prep.initial(
	values.inistate=c(0, 1),
	params.inistate=c('inipos', 'fixed'), #initial position is free parameter 5, initial slope is fixed at 1
	values.inicov=diag(1, 2),
	params.inicov=diag('fixed', 2)) #initial covariance is fixed to a diagonal matrix of 1s.


#initial <- prep.initial(
#	values.inistate=list(c(0, 1), c(0, 1)),
#	params.inistate=list(c('inipos', 'fixed'), c('fixed', 'inivel')), #initial position is free parameter 5, initial slope is fixed at 1
#	values.inicov=list(diag(1, 2), diag(1, 2)),
#	params.inicov=list(diag('fixed', 2), diag('fixed', 2))) #initial covariance is fixed to a diagonal matrix of 1s.




# define the differential equation
dynamics <- prep.matrixDynamics(
	values.dyn=matrix(c(0, -0.1, 1, -0.2), 2, 2),
	params.dyn=matrix(c('fixed', 'spring', 'fixed', 'friction'), 2, 2), #uses parameters 1 and 2
	isContinuousTime=TRUE)


# Data
data(Oscillator)
data <- dynr.data(Oscillator, id="id", time="times", observed="y1")


# Prepare for cooking
# put all the recipes together
model <- dynr.model(dynamics=dynamics, measurement=meas, noise=ecov, initial=initial, data=data, outfile="LinearSDE.c")


# set upper bounds, if you want
model$ub <- c(100, 100, 100, 100, 100)
model$ub <- c(friction=101, spring=100, inipos=103, 100, 100)
model$ub['dnoise'] <- 99






#printex(model,ParameterAs=model$param.names,show=FALSE,printInit=TRUE,
#        outFile="LinearSDE.tex")
#tools::texi2pdf("LinearSDE.tex")
#system(paste(getOption("pdfviewer"), "LinearSDE.pdf"))




# Estimate free parameters
res <- dynr.cook(model, verbose = FALSE, optimization_flag = FALSE)
# Examine results
print(summary(res))
