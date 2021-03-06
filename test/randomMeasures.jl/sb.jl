using Turing
using Turing.RandomMeasures
using Test
using Random

# Data
data = [-2,2,-1.5,1.5]

# Base distribution
mu_0 = mean(data)
sigma_0 = 4
sigma_1 = 0.5
tau0 = 1/sigma_0^2
tau1 = 1/sigma_1^2

# DP parameters
alpha = 0.25

include("utils.jl")

partitions = [[[1, 2, 3, 4]], [[1, 2, 3], [4]], [[1, 2, 4], [3]], [[1, 2], [3, 4]], [[1, 2], [3], [4]],
[[1, 3, 4], [2]], [[1, 3], [2, 4]], [[1, 3], [2], [4]], [[1, 4], [2, 3]], [[1], [2, 3, 4]],
[[1], [2, 3], [4]], [[1, 4], [2], [3]], [[1], [2, 4], [3]], [[1], [2], [3, 4]], [[1], [2], [3], [4]]]

# stick-breaking process based on Papaspiliopoulos and Roberts (2008).
@model sbimm(y, rpm, trunc) = begin
    # Base distribution.
    H = Normal(mu_0, sigma_0)

    # Latent assignments.
    N = length(y)
    z = tzeros(Int, N)

    # Infinite (truncated) collection of breaking points on unit stick.
    v = tzeros(Float64, trunc)

    # Cluster locations.
    x = tzeros(Float64, trunc)

    # Draw weights and locations.
    for k in 1:trunc
        v[k] ~ StickBreakingProcess(rpm)
        x[k] ~ H
    end

    # Weights.
    w = vcat(v[1], v[2:end] .* cumprod(1 .- v[1:end-1]))

    # Normalize weights to ensure they sum exactly to one.
    # This is required by the Categorical distribution in Distributions.
    w ./= sum(w)

    for i in 1:N
        # Draw location
        z[i] ~ Categorical(w)

        # Draw observation.
        y[i] ~ Normal(x[z[i]], sigma_1)
    end
end

rpm = DirichletProcess(alpha)

sampler = SMC(1000)
mf = sbimm(data, rpm, 10)

# Compute empirical posterior distribution over partitions
samples = sample(mf, sampler)

# Check that there is no NaN value associated
z_samples = Int.(samples[:z].value)
@test all(!isnan, samples[:x].value[z_samples])
@test all(!ismissing, samples[:x].value[z_samples])

empirical_probs = zeros(length(partitions))
w = map(x -> x.weight, samples.info[:samples])
sum_weights = sum(w)
z = z_samples

for i in 1:size(z,1)
    partition = map(c -> findall(z[i,:,1] .== c), unique(z[i,:,1]))
    partition_idx = findfirst(p -> sort(p) == sort(partition), partitions)
    @test partition_idx != nothing
    empirical_probs[partition_idx] += sum_weights == 0 ? 1 : w[i]
end

if sum_weights == 0
    empirical_probs /= length(w)
end

l2, discr = correct_posterior(empirical_probs, data, partitions, tau0, tau1, alpha, 1e-7)

# Increased ranges due to truncation error.
@test l2 < 0.1
@test discr < 0.3
