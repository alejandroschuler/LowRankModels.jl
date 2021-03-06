# Predefined loss functions
# You may also implement your own loss by subtyping the abstract type Loss.
#
# Losses must have the following:
#   Fields:
#     `scale::Float64`
#           This field represents a scalar weight assigned to the loss function: w*l(u,a)
#     `domain::natural_Domain`
#           The "natural" domain that the loss function was meant to handle. E.g. BoolDomain for logistic,
#           RealDomain for quadratic, etc.

#   Other fields may be also be included to encode parameters of the loss function, encode the range or  
#   set of possible values of the data, etc.
#
#   Methods:
#     `my_loss_type(args..., scale=1.0::Float64; 
#                   domain=natural_Domain(args[range]...), kwargs...) ::my_loss_type`
#           Constructor for the loss type. The first few arguments are parameters for 
#           which there isn't a rational default (a loss may not need any of these).
#           The last positional argument should be the scale, which should default to 1.
#           There must be a default domain which is a Domain, which may take arguments from 
#           the list of positional arguments. Parameters besides the scale for which there are 
#           reasonable defaults should be included as keyword arguments (there may be none).
#     `evaluate(l::my_loss_type, u::Float64, a::Number) ::Float64` 
#           Evaluates the function l(u,a) where u is the approximation of a
#     `grad(l::my_loss_type, u::Float64, a::Number) ::Float64`
#           Evaluates the gradient of the loss at the given point (u,a)

#   In addition, loss functions should preferably implement a method:
#     `M_estimator(l::my_loss_type, a::AbstractArray) ::Float64`
#           Finds uₒ = argmin ∑l(u,aᵢ) which is the best single estimate of the array `a`
#   If `M_estimator` is not implemented, a live optimization procedure will be used when this function is 
#   called in order to compute loss function scalings. The live optimization may be slow, so an analytic 
#   implementation is preferable.


import Base.scale! 
import Optim.optimize
export Loss, 
       DiffLoss, # a category of Losses
       quadratic, weighted_hinge, hinge, logistic, poisson, ordinal_hinge, l1, huber, periodic, # concrete losses
       evaluate, grad, M_estimator, # methods on losses
       avgerror, scale, scale!

abstract Loss
# a DiffLoss is one in which l(u,a) = f(u-a) AND argmin f(x) = 0
# for example, quadratic(u,a)=(u-a)² and we can write f(x)=x² and x=u-a
abstract DiffLoss<:Loss

scale!(l::Loss, newscale::Number) = (l.scale = newscale; l)
scale(l::Loss) = l.scale

# The following is the M-estimator for loss functions that don't have one defined. It's also useful
# for checking that the analytic M_estimators are correct. To make sure this method is called instead
# of the loss-specific method (should only be done to test), simply pass the third paramter `test`.
# e.g. M_estimator(l,a) will call the implementation for l, but M_estimator(l,a,"test") will call the
# general-purpose optimizing M_estimator.  
function M_estimator(l::Loss, a::AbstractArray; test="test")
    # the function to optimize over
    f = u -> sum(map(ai->evaluate(l,u[1],ai), a)) # u is indexed because `optim` assumes input is a vector
    # the gradient of that function
    function g!(u::Vector, storage::Vector) # this is the format `optim` expects
        storage[1] = sum(map(ai->grad(l,u[1],ai), a))
    end
    m = optimize(f, g!, [median(a)], method=:l_bfgs).minimum[1]
end

# Uses uₒ = argmin ∑l(u,aᵢ) to find (1/n)*∑l(uₒ,aᵢ) which is the 
# average error incurred by using the estimate uₒ for every aᵢ
function avgerror(l::Loss, a::AbstractArray)
    m = M_estimator(l,a)
    sum(map(ai->evaluate(l,m,ai),a))/length(a)
end


## Losses:

########################################## QUADRATIC ##########################################
# f: ℜxℜ -> ℜ
type quadratic<:DiffLoss
    scale::Float64
    domain::Domain
end
quadratic(scale=1.0; domain=RealDomain()) = quadratic(scale, domain)

evaluate(l::quadratic, u::Float64, a::Number) = l.scale*(u-a)^2

grad(l::quadratic, u::Float64, a::Number) = (u-a)*l.scale

M_estimator(l::quadratic, a::AbstractArray) = mean(a)

########################################## L1 ##########################################
# f: ℜxℜ -> ℜ
type l1<:DiffLoss
    scale::Float64
    domain::Domain
end
l1(scale=1.0; domain=RealDomain()) = l1(scale, domain)

evaluate(l::l1, u::Float64, a::Number) = l.scale*abs(u-a)

grad(l::l1, u::Float64, a::Number) = sign(u-a)*l.scale

M_estimator(l::l1, a::AbstractArray) = median(a)

########################################## HUBER ##########################################
# f: ℜxℜ -> ℜ
type huber<:DiffLoss
    scale::Float64
    domain::Domain
    crossover::Float64 # where quadratic loss ends and linear loss begins; =1 for standard huber
end
huber(scale=1.0; domain=RealDomain(), crossover=1.0) = huber(scale, domain, crossover)

function evaluate(l::huber, u::Float64, a::Number)
    abs(u-a) > l.crossover ? (abs(u-a) - l.crossover + l.crossover^2)*l.scale : (u-a)^2*l.scale
end

grad(l::huber,u::Float64,a::Number) = abs(u-a)>l.crossover ? sign(u-a)*l.scale : (u-a)*l.scale

# M_estimator(l::huber, a::AbstractArray) = median(a) # a heuristic, not the true estimator.

########################################## PERIODIC ##########################################
# f: ℜxℜ -> ℜ
# f(u,a) = w * (1 - cos((a-u)*(2*pi)/T))
# this measures how far away u and a are on a circle of circumference T. 
type periodic<:DiffLoss
    T::Float64 # the length of the period
    scale::Float64
    domain::Domain
end
periodic(T, scale=1.0; domain=PeriodicDomain(T)) = periodic(T, scale, domain)

evaluate(l::periodic, u::Float64, a::Number) = l.scale*(1-cos((a-u)*(2*pi)/l.T))

grad(l::periodic, u::Float64, a::Number) = -l.scale*((2*pi)/l.T)*sin((a-u)*(2*pi)/l.T)

function M_estimator(l::periodic, a::AbstractArray)
    (l.T/(2*pi))*atan( sum(sin(2*pi*a/l.T)) / sum(cos(2*pi*a/l.T)) ) + l.T/2 # not kidding. 
    # this is the estimator, and there is a form that works with weighted measurements (aka a prior on a)
    # see: http://www.tandfonline.com/doi/pdf/10.1080/17442507308833101 eq. 5.2
end 

########################################## POISSON ##########################################
# f: ℜxℕ -> ℜ
# BEWARE: THIS LOSS MAY CAUSE MODEL INSTABLITY AND DIFFICULTY FITTING.
type poisson<:Loss
    scale::Float64
    domain::Domain
end
poisson(max_count::Int, scale=1.0; domain=CountDomain(max_count)) = poisson(scale, domain)

function evaluate(l::poisson, u::Float64, a::Number) 
    exp(u) - a*u # in reality this should be: e^u - a*u + a*log(a) - a, but a*log(a) - a is constant wrt a!
end

grad(l::poisson, u::Float64, a::Number) = exp(u) - a

M_estimator(l::poisson, a::AbstractArray) = log(mean(a))

########################################## ORDINAL HINGE ##########################################
# f: ℜx{min, min+1... max-1, max} -> ℜ
type ordinal_hinge<:Loss
    min::Integer
    max::Integer
    scale::Float64
    domain::Domain
end
ordinal_hinge(m1, m2, scale=1.0; domain=OrdinalDomain(m1,m2)) = ordinal_hinge(m1,m2,scale,domain)

function evaluate(l::ordinal_hinge, u::Float64, a::Number)
    #a = round(a)
    if u > l.max-1
        # number of levels higher than true level
        n = min(floor(u), l.max-1) - a
        loss = n*(n+1)/2 + (n+1)*(u-l.max+1)
    elseif u > a
        # number of levels higher than true level
        n = min(floor(u), l.max) - a
        loss = n*(n+1)/2 + (n+1)*(u-floor(u))
    elseif u > l.min+1
        # number of levels lower than true level
        n = a - max(ceil(u), l.min+1)
        loss = n*(n+1)/2 + (n+1)*(ceil(u)-u)
    else
        # number of levels higher than true level
        n = a - max(ceil(u), l.min+1)
        loss = n*(n+1)/2 + (n+1)*(l.min+1-u)
    end
    return l.scale*loss
end

function grad(l::ordinal_hinge, u::Float64, a::Number)
    #a = round(a)
    if u > a
        # number of levels higher than true level
        n = min(ceil(u), l.max) - a
        g = n
    else
        # number of levels lower than true level
        n = a - max(floor(u), l.min)
        g = -n
    end
    return l.scale*g
end

M_estimator(l::ordinal_hinge, a::AbstractArray) = median(a)

########################################## LOGISTIC ##########################################
# f: ℜx{-1,1}-> ℜ
type logistic<:Loss
    scale::Float64
    domain::Domain
end
logistic(scale=1.0; domain=BoolDomain()) = logistic(scale, domain)

evaluate(l::logistic, u::Float64, a::Number) = l.scale*log(1+exp(-a*u))

grad(l::logistic, u::Float64, a::Number) = -a*l.scale/(1+exp(a*u))

function M_estimator(l::logistic, a::AbstractArray)
    d, N = sum(a), length(a)
    log(N + d) - log(N - d) # very satisfying
end

########################################## WEIGHTED HINGE ##########################################
# f: ℜx{-1,1} -> ℜ
# f(u,a) = {     w * max(0, u) for a = -1
#        = { c * w * max(0,-u) for a =  1
type weighted_hinge<:Loss
    scale::Float64
    domain::Domain
    case_weight_ratio::Float64 # >1 for trues to have more confidence than falses, <1 for opposite
end
weighted_hinge(scale=1.0; domain=BoolDomain(), case_weight_ratio=1.0) = 
    weighted_hinge(scale, domain, case_weight_ratio)
hinge(scale=1.0; kwargs...) = weighted_hinge(scale; kwargs...) # the standard hinge is a special case of weighted hinge

function evaluate(l::weighted_hinge, u::Float64, a::Number)
    loss = l.scale*max(1-a*u, 0)
    if a>0 # if for whatever reason someone doesn't use properly coded variables...
        loss *= l.case_weight_ratio
    end
    return loss
end

function grad(l::weighted_hinge, u::Float64, a::Number)
    g = (a*u>=1 ? 0 : -a*l.scale)
    if a>0
        g *= l.case_weight_ratio
    end
    return g
end

function M_estimator(l::weighted_hinge, a::AbstractArray)
    r = length(a)/length(filter(x->x>0, a)) - 1 
    if l.case_weight_ratio > r
        m = 1.0
    elseif l.case_weight_ratio == r
        m = 0.0
    else
        m = -1.0
    end
end
