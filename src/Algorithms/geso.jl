@params mutable struct GESOResult{T}
    topology::AbstractVector{T}
    objval::T
    change::T
    converged::Bool
    fevals::Int
end
@params struct GESO{T} <: TopOptAlgorithm 
    obj
    constr
    vars::AbstractVector{T}
    topology::AbstractVector{T}
    Pcmin::T
    Pcmax::T
    Pmmin::T
    Pmmax::T
    Pen::T
    string_length::Int
    var_volumes::AbstractVector{T}
    cum_var_volumes::AbstractVector{T}
    order::AbstractVector{Int}
    genotypes::BitArray{2}
    children::BitArray{2}
    var_black::BitVector
    maxiter::Int
    penalty
    sens::AbstractVector{T}
    old_sens::AbstractVector{T}
    obj_trace::MVector{10, T}
    tol::T
    sens_tol::T
    result::GESOResult{T}
end

function GESO(obj::Objective{<:ComplianceFunction}, constr::Constraint{<:VolumeFunction}; maxiter = 1000, tol = 0.001, p = 3., Pcmin = 0.6, Pcmax = 1., Pmmin = 0.5, Pmmax = 1., Pen = 3., sens_tol = tol/100, string_length = 4)
    penalty = obj.solver.penalty
    penalty = @set penalty.p = p
    T = typeof(obj.comp)
    nel = getncells(obj.problem.ch.dh.grid)
    black = obj.problem.black
    white = obj.problem.white
    nvars = nel - sum(black) - sum(white)
    vars = zeros(T, nvars)

    topology = zeros(T, nel)
    result = GESOResult(topology, T(NaN), T(NaN), false, 0)
    sens = zeros(T, nvars)
    old_sens = zeros(T, nvars)
    obj_trace = zeros(MVector{10, T})
    var_volumes = constr.cellvolumes[.!black .& .!white]
    cum_var_volumes = zeros(T, nvars)
    order = zeros(Int, nvars)
    genotypes = trues(string_length, nvars)
    children = trues(string_length, nvars)
    var_black = trues(nvars)

    return GESO(obj, constr, vars, topology, Pcmin, Pcmax, Pmmin, Pmmax, Pen, string_length, var_volumes, cum_var_volumes, order, genotypes, children, var_black, maxiter, penalty, sens, old_sens, obj_trace, tol, sens_tol, result)
end

update_penalty!(b::GESO, p::Number) = (b.penalty.p = p)

get_progress(current_volume, total_volume, design_volume) = clamp(min((total_volume - current_volume) / (total_volume - design_volume), current_volume / design_volume), 0, 1)

get_probs(b::GESO, Prg) = (b.Pcmin + (b.Pcmax - b.Pcmin)*Prg^b.Pen, b.Pmmin + (b.Pmmax - b.Pmmin)*Prg^b.Pen)

function crossover!(children, genotypes, i, j)
    for k in 1:size(genotypes, 1)
        r = rand()
        if r < 0.5
            children[k,i] = genotypes[k,i]
        else
            children[k,i] = genotypes[k,j]
        end
    end
    return
end

function update!(var_black, children, genotypes, Pc, Pm, high_class, mid_class, low_class)
    topology_changed = false
    while !topology_changed
        for i in high_class
            r = rand()
            j = i
            if length(high_class) > 1
                if r < Pc
                    while i == j
                        j = rand(high_class)
                    end
                elseif r < 0.5 + 0.5*Pc
                    j = rand(mid_class)
                else
                    j = rand(low_class)
                end
            else
                if r < 0.5
                    j = rand(mid_class)
                else
                    j = rand(low_class)
                end
            end
            crossover!(children, genotypes, i, j)
        end
        for i in mid_class
            r = rand()
            j = i
            if length(mid_class) > 1
                if r < Pc 
                    while i == j
                        j = rand(mid_class)
                    end
                elseif r < 0.5 + 0.5*Pc
                    j = rand(high_class)
                else
                    j = rand(low_class)
                end
            else
                if r < 0.5 + 0.5*Pc
                    j = rand(high_class)
                else
                    j = rand(low_class)
                end
            end
            crossover!(children, genotypes, i, j)
        end
        for i in low_class
            r = rand()
            j = i
            if length(low_class) > 1
                if r < Pc
                    while i == j
                        j = rand(low_class)
                    end
                elseif r < 0.5 + 0.5*Pc
                    j = rand(mid_class)
                else
                    j = rand(high_class)
                end
            else
                if r < 0.5
                    j = rand(mid_class)
                else
                    j = rand(high_class)
                end
            end
            crossover!(children, genotypes, i, j)
        end
        genotypes .= children

        for i in high_class
            for j in 1:size(genotypes, 1)
                r = rand()
                if r < Pm && !genotypes[j,i]
                    genotypes[j,i] = !genotypes[j,i]
                end
            end
            if any(@view genotypes[:,i]) != var_black[i]
                var_black[i] = !var_black[i]
                topology_changed = true
            end
        end
        for i in mid_class
            for j in 1:size(genotypes, 1)
                r = rand()
                if r < Pm && genotypes[j,i]
                    genotypes[j,i] = !genotypes[j,i]
                end
            end
            if any(@view genotypes[:,i]) != var_black[i]
                var_black[i] = !var_black[i]
                topology_changed = true
            end
        end
        for i in low_class
            for j in 1:size(genotypes, 1)
                r = rand()
                if r < Pm && genotypes[j,i]
                    genotypes[j,i] = !genotypes[j,i]
                end
            end
            if any(@view genotypes[:,i]) != var_black[i]
                var_black[i] = !var_black[i]
                topology_changed = true
            end
        end
    end

    return var_black
end

function (b::GESO{TO, TC, T})(x0=copy(b.obj.solver.vars); seed=NaN) where {TO<:Objective{<:ComplianceFunction}, TC<:Constraint{<:VolumeFunction}, T}
    @unpack sens, old_sens, tol, maxiter = b
    @unpack obj_trace, topology, sens_tol, vars = b
    @unpack Pcmin, Pcmax, Pmmin, Pmmax, Pen = b
    @unpack string_length, genotypes, children, var_black = b
    @unpack cum_var_volumes, var_volumes, order = b
    @unpack varind, black, white = b.obj.f.problem
    @unpack total_volume, cellvolumes, fixed_volume = b.constr.f
    V = b.constr.s
    design_volume = V * total_volume

    nel = length(x0)
    nvars = length(vars)

    # Set seed
    isnan(seed) || Random.seed!(seed)

    # Initialize the topology
    for i in 1:length(topology)
        if black[i]
            topology[i] = 1
        elseif white[i]
            topology[i] = 0
        else
            topology[i] = round(x0[varind[i]])
            vars[varind[i]] = topology[i]
        end
    end

    check(x) = x > design_volume - fixed_volume
    #rrmax = clamp(1 - design_volume/current_volume, 0, 1)
    current_volume = dot(vars, var_volumes) + fixed_volume
    vol = current_volume/total_volume
    # Main loop
    change = T(1)
    iter = 0
    while (change > tol || vol > V) && iter < maxiter
        iter += 1
        if iter > 1
            old_sens .= sens
        end
        for j in max(2, 10-iter+2):10
            obj_trace[j-1] = obj_trace[j]
        end
        obj_trace[10] = b.obj(vars, sens)
        rmul!(sens, -1)
        if iter > 1
            @. sens = (sens + old_sens) / 2
        end
        
        # Classify the cells by their sensitivities
        sortperm!(order, sens, rev=true)
        accumulate!(+, cum_var_volumes, view(var_volumes, order))
        N1 = findfirst(check, cum_var_volumes) - 1
        N2 = (nel - N1) ÷ 2
        N3 = nvars - N1 - N2
        high_class = @view order[1:N1]
        mid_class = @view order[N1+1:N1+N2]
        low_class = @view order[N1+N2+1:end]

        # Crossover and mutation
        Prg = get_progress(current_volume, total_volume, design_volume)
        Pc, Pm = get_probs(b, Prg)        
        vars .= update!(var_black, children, genotypes, Pc, Pm, high_class, mid_class, low_class)

        # Update crossover and mutation probabilities
        current_volume = dot(vars, var_volumes) + fixed_volume
        vol = current_volume/total_volume

        if iter >= 10
            l = sum(@view obj_trace[1:5])
            h = sum(@view obj_trace[6:10])
            change = abs(l-h)/h
        end
    end

    for i in 1:length(topology)
        if black[i]
            topology[i] = 1
        elseif white[i]
            topology[i] = 0
        else
            topology[i] = vars[varind[i]]            
        end
    end

    b.result.objval = obj_trace[10]
    b.result.change = change
    b.result.converged = change <= tol
    b.result.fevals = iter

    return b.result
end
