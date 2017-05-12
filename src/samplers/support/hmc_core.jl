global Δ_max = 1000

setchunksize(chun_size::Int) = global CHUNKSIZE = chunk_size

runmodel(model::Function, vi::VarInfo, spl::Union{Void,Sampler}) = begin
  dprintln(4, "run model...")
  vi.index = 0
  setlogp!(vi, zero(Real))
  if spl != nothing spl.info[:eval_num] += 1 end
  model(vi=vi, sampler=spl) # run model
end

sample_momentum(vi::VarInfo, spl::Sampler) = begin
  dprintln(2, "sampling momentum...")
  randn(length(getranges(vi, spl)))
end

# Leapfrog step
leapfrog2(θ::Vector, p::Vector, τ::Int, ϵ::Float64,
          model::Function, vi::VarInfo, spl::Sampler) = begin

  vi[spl] = θ
  grad = gradient2(vi, model, spl)
  verifygrad(grad) || (return θ, p, 0)

  τ_valid = 0
  for t in 1:τ
    p_old = copy(p); θ_old = θ; old_logp = getlogp(vi)

    p -= ϵ * grad / 2
    θ += ϵ * p  # full step for state
    spl.info[:lf_num] += 1  # record leapfrog num

    vi[spl] = θ
    grad = gradient2(vi, model, spl)
    verifygrad(grad) || (vi[spl] = θ_old; setlogp!(vi, old_logp); θ = θ_old; p = p_old; break)

    p -= ϵ * grad / 2

    τ_valid += 1
  end

  θ, p, τ_valid
end

leapfrog(vi::VarInfo, p::Vector, τ::Int, ϵ::Float64, model::Function, spl::Sampler) = begin

  dprintln(3, "first gradient...")
  grad = gradient2(vi, model, spl)
  # Verify gradients; reject if gradients is NaN or Inf.


  dprintln(2, "leapfrog stepping...")
  τ_valid = 0
  for t in 1:τ        # do 'leapfrog' for each var
    p_old = copy(p); θ_old = vi[spl]

    p -= ϵ * grad / 2

    vi[spl] += ϵ * p  # full step for state

    grad = gradient2(vi, model, spl)

    # Verify gradients; reject if gradients is NaN or Inf
    verifygrad(grad) || (vi[spl] = θ_old; p = p_old; break)

    p -= ϵ * grad / 2

    τ_valid += 1
  end

  # Return updated θ and momentum
  vi, p, τ_valid
end

find_H(p::Vector, logp::Real) = begin
  H = dot(p, p) / 2 + realpart(-logp)
  if isnan(H) H = Inf else H end
end

# Compute Hamiltonian
find_H(p::Vector, model::Function, vi::VarInfo, spl::Sampler) = begin
  # NOTE: getlogp(vi) = 0 means the current vals[end] hasn't been used at all.
  #       This can be a result of link/invlink (where expand! is used)
  if getlogp(vi) == 0 vi = runmodel(model, vi, spl) end

  H = dot(p, p) / 2 + realpart(-getlogp(vi))
  if isnan(H) H = Inf else H end
end

find_good_eps{T}(model::Function, vi::VarInfo, spl::Sampler{T}) = begin
  ϵ, p = 1.0, sample_momentum(vi, spl)    # set initial epsilon and momentums
  log_p_r_Θ = -find_H(p, model, vi, spl)  # calculate p(Θ, r) = exp(-H(Θ, r))

  θ = vi[spl]
  θ_prime, p_prime, τ = leapfrog2(θ, p, 1, ϵ, model, vi, spl)
  log_p_r_Θ′ = τ == 0 ? -Inf : -find_H(p_prime, model, vi, spl)   # calculate new p(Θ, p)

  # Heuristically find optimal ϵ
  a = 2.0 * (log_p_r_Θ′ - log_p_r_Θ > log(0.5) ? 1 : 0) - 1
  while (exp(log_p_r_Θ′ - log_p_r_Θ))^a > 2.0^(-a)
    ϵ = 2.0^a * ϵ
    θ_prime, p_prime, τ = leapfrog2(θ, p, 1, ϵ, model, vi, spl)
    log_p_r_Θ′ = τ == 0 ? -Inf : -find_H(p_prime, model, vi, spl)
    dprintln(1, "a = $a, log_p_r_Θ′ = $log_p_r_Θ′")
  end

  println("\r[$T] found initial ϵ: ", ϵ)
  ϵ
end
