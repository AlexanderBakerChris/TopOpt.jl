@params mutable struct PCGDisplacementSolver{T, dim, TP<:AbstractPenalty{T}} <: AbstractDisplacementSolver
    problem::StiffnessTopOptProblem{dim, T}
    globalinfo::GlobalFEAInfo{T}
    elementinfo::ElementFEAInfo{dim, T}
    u::AbstractVector{T}
    lhs::AbstractVector{T}
    rhs::AbstractVector{T}
    vars::AbstractVector{T}
    penalty::TP
    prev_penalty::TP
    xmin::T
    cg_max_iter::Integer
    tol::T
    cg_statevars::CGStateVariables{T, <:AbstractVector{T}}
    preconditioner
    preconditioner_initialized::Ref{Bool}
    conv
end
function PCGDisplacementSolver(sp::StiffnessTopOptProblem{dim, T};
    conv = DefaultCriteria(),
    xmin=T(1)/1000, 
    cg_max_iter=700, 
    tol=xmin, 
    penalty=PowerPenalty{T}(1), 
    prev_penalty=copy(penalty),
    preconditioner=identity, 
    quad_order=default_quad_order(sp)) where {dim, T, Tconv}

    prev_penalty = @set prev_penalty.p = T(NaN)
    elementinfo = ElementFEAInfo(sp, quad_order, Val{:Static})
    globalinfo = GlobalFEAInfo(sp)
    u = zeros(T, ndofs(sp.ch.dh))
    lhs = similar(u)
    rhs = similar(u)
    vars = fill(one(T), getncells(sp.ch.dh.grid) - sum(sp.black) - sum(sp.white))
    varind = sp.varind
    us = similar(u) .= 0
    cg_statevars = CGStateVariables{eltype(u), typeof(u)}(us, similar(u), similar(u))

    return PCGDisplacementSolver(sp, globalinfo, elementinfo, u, lhs, rhs, vars, penalty, prev_penalty, xmin, cg_max_iter, tol, cg_statevars, preconditioner, Ref(false), conv)
end

function (s::PCGDisplacementSolver{T})(::Type{Val{safe}} = Val{false}; assemble_f = true) where {T, safe}
    rhs = assemble_f ? s.globalinfo.f : s.rhs
    lhs = assemble_f ? s.u : s.lhs
    globalinfo = GlobalFEAInfo(s.globalinfo.K, rhs)
    assemble!(globalinfo, s.problem, s.elementinfo, s.vars, s.penalty, s.xmin, assemble_f = assemble_f)
    Tconv = typeof(s.conv)
    K, f = globalinfo.K, globalinfo.f
    if safe
        m = meandiag(K)
        for i in 1:size(K,1)
            if K[i,i] ≈ zero(T)
                K[i,i] = m
            end
        end
    end

    @unpack cg_max_iter, tol, cg_statevars = s
    @unpack preconditioner, preconditioner_initialized = s

    _K = K isa Symmetric ? K.data : K
    if !(preconditioner === identity)
        if !preconditioner_initialized[]
            UpdatePreconditioner!(preconditioner, _K)
            preconditioner_initialized[] = true
        end
    end
    op = MatrixOperator(_K, f, s.conv)
    if preconditioner === identity
        return cg!(lhs, op, f, tol=tol, maxiter=cg_max_iter, log=false, statevars=cg_statevars, initially_zero=false)
    else
        return cg!(lhs, op, f, tol=tol, maxiter=cg_max_iter, log=false, statevars=cg_statevars, initially_zero=false, Pl = preconditioner)
    end
end
