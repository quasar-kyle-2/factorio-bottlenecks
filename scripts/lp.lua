-- Revised bounded-variable primal simplex for problems where x = 0 is feasible.
--
-- Problem form (all variables have lower bound 0):
--   for each row i:  sum_j A[i][j] * x_j + s_i = b_i,   b_i >= 0,   0 <= s_i <= slack_upper[i] (nil = inf)
--   0 <= x_j <= upper[j] (nil = inf)
--   minimize  sum_k weights[k] * (costs[k] . x)
--
-- The basis inverse is kept in product form: a sparse LU factorization (Markowitz
-- pivoting) refreshed every REINVERT_EVERY iterations, plus one update per pivot.
-- The starting basis is all slacks, so no phase 1 is needed. The state is plain
-- tables (no metatables or functions) so it can live in `storage` and be advanced
-- a slice at a time from on_tick.
--
-- Each cost component k keeps its own reduced-cost row, so after solving we can
-- read the marginal value of every bound per objective component.

local lp = {}

local INF = math.huge
local PIVOT_TOL = 1e-9
local OPT_TOL = 1e-10
local DROP_TOL = 1e-14
local TIE_TOL = 1e-12
local BLAND_AFTER = 50
local REINVERT_EVERY = 48
--- Dual simplex (after lp.set_bound): smallest pivot taken, and how far outside its bounds a
--- basic variable may be (relative to the bound) before it counts as infeasible.
local DUAL_PIVOT_TOL = 1e-7
local FEAS_TOL = 1e-9

---@class LP.Problem
---@field n integer
---@field m integer
---@field cols table<integer, table<integer, number>>
---@field upper table<integer, number>
---@field b table<integer, number>
---@field slack_upper table<integer, number>
---@field costs table<integer, number>[]
---@field weights number[]

---@param p LP.Problem
function lp.create(p)
    local n, m = p.n, p.m
    local N = n + m
    local A, rowA, upper = {}, {}, {}
    for i = 1, m do
        rowA[i] = {}
    end
    for j = 1, n do
        local c = {}
        -- locked columns (upper bound 0) stay out of the row index, so pivots don't pay for them
        local locked = p.upper[j] == 0
        for i, a in pairs(p.cols[j] or {}) do
            if (a ~= 0) then
                c[i] = a
                if (not locked) then
                    rowA[i][j] = a
                end
            end
        end
        A[j] = c
        upper[j] = p.upper[j]
    end

    local basis, pos, beta, b = {}, {}, {}, {}
    for i = 1, m do
        local j = n + i
        upper[j] = p.slack_upper[i]
        basis[i] = j
        pos[j] = i
        beta[i] = p.b[i]
        b[i] = p.b[i]
    end

    local K = #p.costs
    local c, d = {}, {}
    for k = 1, K do
        local ck, dk = {}, {}
        local src = p.costs[k]
        for j = 1, N do
            local v = src[j] or 0
            ck[j] = v
            dk[j] = v
        end
        c[k] = ck
        d[k] = dk
    end

    local st = {
        n = n,
        m = m,
        N = N,
        K = K,
        A = A,
        rowA = rowA,
        upper = upper,
        b = b,
        basis = basis,
        pos = pos,
        beta = beta,
        at_upper = {},
        c = c,
        d = d,
        weights = p.weights,
        etas = {},
        since = 0,
        iterations = 0,
        max_iterations = 30 * N + 1000,
        degenerate_run = 0,
        status = "running",
        work = 0,
    }
    lp.update_tolerance(st)
    return st
end

--- The optimality tolerance scales with the largest weighted cost of a usable column, so
--- rounding noise in heavily weighted costs (planning mode) is not taken for an improvement.
function lp.update_tolerance(st)
    local max_c = 0
    for k = 1, st.K do
        local w, ck = math.abs(st.weights[k]), st.c[k]
        for j = 1, st.N do
            if (st.upper[j] ~= 0) then
                local v = ck[j] * w
                if (v > max_c) then
                    max_c = v
                elseif (-v > max_c) then
                    max_c = -v
                end
            end
        end
    end
    st.opt_tol = OPT_TOL * math.max(1, max_c / 1000)
end

--- Column j of [A | I] as a fresh table.
local function column(st, j)
    local result = {}
    if (j > st.n) then
        result[j - st.n] = 1
    else
        for i, a in pairs(st.A[j]) do
            result[i] = a
        end
    end
    return result
end

--- v := B^-1 v (in place)
local function ftran(st, v)
    local etas = st.etas
    local work = 0
    for k = 1, #etas do
        local e = etas[k]
        local p = e.p
        local vp = v[p]
        if (vp and vp ~= 0) then
            local idx, val = e.idx, e.val
            local cnt = #idx
            -- idx[1] is always p (add_eta and reinvert put it first), and p appears nowhere else
            v[p] = val[1] * vp
            for s = 2, cnt do
                local i = idx[s]
                v[i] = (v[i] or 0) + val[s] * vp
            end
            work = work + cnt
        end
    end
    st.work = st.work + work + #etas
    return v
end

local sort = table.sort

--- u := u^T B^-1 (in place)
local function btran(st, u)
    local etas = st.etas
    local work = 0
    -- entries in u: each eta sets or clears only u[p]
    local nu = 0
    for _ in pairs(u) do
        nu = nu + 1
    end
    local hits = {}
    for k = #etas, 1, -1 do
        local e = etas[k]
        local idx, val = e.idx, e.val
        local cnt = #idx
        local acc = 0
        local at = e.at
        if (at and nu * 6 < cnt) then
            -- A long eta and few entries in u: the same terms, added in the same order (by
            -- position in idx), found from u's side.
            local nh = 0
            for i, _ in pairs(u) do
                local s = at[i]
                if (s) then
                    nh = nh + 1
                    hits[nh] = s
                end
            end
            if (nh > 1) then
                for h = #hits, nh + 1, -1 do
                    hits[h] = nil
                end
                sort(hits)
            end
            for h = 1, nh do
                local s = hits[h]
                acc = acc + u[idx[s]] * val[s]
            end
        else
            for s = 1, cnt do
                local ui = u[idx[s]]
                if (ui) then
                    acc = acc + ui * val[s]
                end
            end
        end
        work = work + cnt
        local p = e.p
        if (acc > DROP_TOL or acc < -DROP_TOL) then
            if (u[p] == nil) then
                nu = nu + 1
            end
            u[p] = acc
        elseif (u[p] ~= nil) then
            nu = nu - 1
            u[p] = nil
        end
    end
    st.work = st.work + work
    return u
end

--- Every eta's idx[1] is its pivot row p, which appears nowhere else in idx (ftran relies on it).
--- Update etas are often long: `at` (row -> position in idx) lets btran pick out the few
--- entries it needs.
local function add_eta(etas, alpha, r)
    local ar = alpha[r]
    local idx, val = { r }, { 1 / ar }
    for i, a in pairs(alpha) do
        if (i ~= r and (a > DROP_TOL or a < -DROP_TOL)) then
            idx[#idx + 1] = i
            val[#val + 1] = -a / ar
        end
    end
    local at
    if (#idx >= 24) then
        at = {}
        for s = 1, #idx do
            at[idx[s]] = s
        end
    end
    etas[#etas + 1] = { p = r, idx = idx, val = val, at = at }
end

-- Binary min-heap of (count, j), ordered by count, then j. Each entry is one number,
-- count * S + j with S > every column index, which orders the same way (exact in a double).
local floor = math.floor

local function heap_push(h, cnt, j)
    local hk = h.k
    local key = cnt * h.S + j
    local k = h.n + 1
    h.n = k
    while (k > 1) do
        local parent = floor(k / 2)
        local pk = hk[parent]
        if (key < pk) then
            hk[k] = pk
            k = parent
        else
            break
        end
    end
    hk[k] = key
end

local function heap_pop(h)
    local hk = h.k
    local top = hk[1]
    local last = h.n
    local x = hk[last]
    hk[last] = nil
    last = last - 1
    h.n = last
    if (last > 0) then
        local k = 1
        while (true) do
            local l = 2 * k
            if (l > last) then
                break
            end
            local smallest, sv = l, hk[l]
            local r = l + 1
            if (r <= last) then
                local rv = hk[r]
                if (rv < sv) then
                    smallest, sv = r, rv
                end
            end
            if (sv < x) then
                hk[k] = sv
                k = smallest
            else
                break
            end
        end
        hk[k] = x
    end
    local S = h.S
    local j = top % S
    return (top - j) / S, j
end

--- Recompute basic values and all reduced costs from scratch for the current factorization.
local function refresh(st)
    local n, m = st.n, st.m
    local rhs = {}
    for i = 1, m do
        rhs[i] = st.b[i]
    end
    for j, up in pairs(st.at_upper) do
        if (up and not st.pos[j]) then
            local u = st.upper[j]
            if (j > n) then
                local i = j - n
                rhs[i] = rhs[i] - u
            else
                for i, a in pairs(st.A[j]) do
                    rhs[i] = rhs[i] - a * u
                end
            end
        end
    end
    local x = ftran(st, rhs)
    local beta = st.beta
    for i = 1, m do
        beta[i] = x[i] or 0
    end

    local basis, pos, A = st.basis, st.pos, st.A
    for k = 1, st.K do
        local ck, dk = st.c[k], st.d[k]
        local y = {}
        for i = 1, m do
            local v = ck[basis[i]]
            if (v ~= 0) then
                y[i] = v
            end
        end
        btran(st, y)
        local upper = st.upper
        for j = 1, n do
            if (pos[j] or upper[j] == 0) then
                -- locked columns (upper bound 0) can never enter; lp.restart refreshes them
                dk[j] = 0
            else
                local v = ck[j]
                for i, a in pairs(A[j]) do
                    local yi = y[i]
                    if (yi) then
                        v = v - yi * a
                    end
                end
                dk[j] = v
            end
        end
        for i = 1, m do
            local j = n + i
            if (pos[j]) then
                dk[j] = 0
            else
                dk[j] = ck[j] - (y[i] or 0)
            end
        end
        st.work = st.work + st.N
    end
end

--- Sparse LU of the current basis (Markowitz pivoting), stored as product-form etas:
--- L etas in elimination order, then U etas in reverse order.
---@return boolean ok
local function reinvert(st)
    local n, m = st.n, st.m
    local rows, rowcount = {}, {}
    for i = 1, m do
        rows[i] = {}
        rowcount[i] = 0
    end
    local colrows, colcount = {}, {}
    local heap = { n = 0, k = {}, S = st.N + 1 }
    for i = 1, m do
        local j = st.basis[i]
        local cr, cnt = {}, 0
        if (j > n) then
            local r = j - n
            rows[r][j] = 1
            rowcount[r] = rowcount[r] + 1
            cr[r] = true
            cnt = 1
        else
            for r, a in pairs(st.A[j]) do
                rows[r][j] = a
                rowcount[r] = rowcount[r] + 1
                cr[r] = true
                cnt = cnt + 1
            end
        end
        colrows[j] = cr
        colcount[j] = cnt
        heap_push(heap, cnt, j)
    end

    local etas = {}
    local pivots = {}
    local done = {}
    local work = 0
    while (heap.n > 0) do
        local cnt, j = heap_pop(heap)
        if (not done[j] and cnt == colcount[j]) then
            local cands = { j }
            local extra_c, extra_j
            while (heap.n > 0 and #cands < 4) do
                local c2, j2 = heap_pop(heap)
                if (not done[j2] and c2 == colcount[j2]) then
                    if (c2 > cnt + 1) then
                        extra_c, extra_j = c2, j2
                        break
                    end
                    cands[#cands + 1] = j2
                end
            end

            local best_score, best_r, best_c, best_a
            for _, jc in ipairs(cands) do
                local cc = colcount[jc]
                if (cc > 0) then
                    local mx = 0
                    for i, _ in pairs(colrows[jc]) do
                        local a = rows[i][jc]
                        if (a < 0) then a = -a end
                        if (a > mx) then mx = a end
                    end
                    for i, _ in pairs(colrows[jc]) do
                        local a = rows[i][jc]
                        local aa = a < 0 and -a or a
                        if (aa >= 0.1 * mx and aa >= 1e-12) then
                            local score = (rowcount[i] - 1) * (cc - 1)
                            local better = false
                            if (best_score == nil or score < best_score) then
                                better = true
                            elseif (score == best_score) then
                                local ba = best_a < 0 and -best_a or best_a
                                if (aa > ba or (aa == ba and (jc < best_c or (jc == best_c and i < best_r)))) then
                                    better = true
                                end
                            end
                            if (better) then
                                best_score, best_r, best_c, best_a = score, i, jc, a
                            end
                        end
                    end
                end
            end
            for _, jc in ipairs(cands) do
                if (jc ~= best_c) then
                    heap_push(heap, colcount[jc], jc)
                end
            end
            if (extra_j) then
                heap_push(heap, extra_c, extra_j)
            end
            if (not best_c) then
                return false
            end

            local r, c, p = best_r, best_c, best_a
            done[c] = true
            local prow = rows[r]
            rows[r] = nil
            local lidx, lval = { r }, { 1 }
            for i, _ in pairs(colrows[c]) do
                if (i ~= r) then
                    local ri = rows[i]
                    local f = ri[c] / p
                    lidx[#lidx + 1] = i
                    lval[#lval + 1] = -f
                    for jj, a in pairs(prow) do
                        if (jj ~= c) then
                            local old = ri[jj]
                            local v = (old or 0) - f * a
                            if (v > DROP_TOL or v < -DROP_TOL) then
                                if (old == nil) then
                                    colrows[jj][i] = true
                                    colcount[jj] = colcount[jj] + 1
                                    rowcount[i] = rowcount[i] + 1
                                end
                                ri[jj] = v
                            elseif (old ~= nil) then
                                ri[jj] = nil
                                colrows[jj][i] = nil
                                colcount[jj] = colcount[jj] - 1
                                rowcount[i] = rowcount[i] - 1
                            end
                            work = work + 1
                        end
                    end
                    ri[c] = nil
                    rowcount[i] = rowcount[i] - 1
                end
            end
            local urow = {}
            for jj, a in pairs(prow) do
                colrows[jj][r] = nil
                colcount[jj] = colcount[jj] - 1
                if (jj ~= c) then
                    urow[jj] = a
                    if (not done[jj]) then
                        heap_push(heap, colcount[jj], jj)
                    end
                end
            end
            colrows[c] = nil
            if (#lidx > 1) then
                etas[#etas + 1] = { p = r, idx = lidx, val = lval }
            end
            pivots[#pivots + 1] = { r = r, c = c, p = p, urow = urow }
        end
    end

    if (#pivots ~= m) then
        return false
    end

    local ucol = {}
    for _, pv in ipairs(pivots) do
        ucol[pv.c] = {}
    end
    for _, pv in ipairs(pivots) do
        for jj, a in pairs(pv.urow) do
            local list = ucol[jj]
            list[#list + 1] = pv.r
            list[#list + 1] = a
        end
    end
    for k = #pivots, 1, -1 do
        local pv = pivots[k]
        local idx, val = { pv.r }, { 1 / pv.p }
        local list = ucol[pv.c]
        for s = 1, #list, 2 do
            idx[#idx + 1] = list[s]
            val[#val + 1] = -list[s + 1] / pv.p
        end
        if (#idx > 1 or pv.p ~= 1) then
            etas[#etas + 1] = { p = pv.r, idx = idx, val = val }
        end
    end

    local basis, pos = {}, {}
    for _, pv in ipairs(pivots) do
        basis[pv.r] = pv.c
        pos[pv.c] = pv.r
    end
    st.basis = basis
    st.pos = pos
    st.etas = etas
    st.since = 0
    st.work = st.work + work + m
    refresh(st)
    return true
end

local function choose_entering(st)
    local pos, at_upper, upper = st.pos, st.at_upper, st.upper
    local d, w, K = st.d, st.weights, st.K
    local bland = st.degenerate_run > BLAND_AFTER
    local best, best_score = nil, st.opt_tol or OPT_TOL
    if (K == 1) then
        -- same test as below: score = dj at the upper bound, -dj at 0, must beat best_score
        local d1, w1 = d[1], w[1]
        for j = 1, st.N do
            local dj = w1 * d1[j]
            local score
            if (-dj > best_score) then
                if (not at_upper[j]) then
                    score = -dj
                end
            elseif (dj > best_score) then
                if (at_upper[j]) then
                    score = dj
                end
            end
            if (score and not pos[j] and upper[j] ~= 0) then
                if (bland) then
                    return j
                end
                best, best_score = j, score
            end
        end
        st.work = st.work + st.N * K
        return best
    end
    for j = 1, st.N do
        if (not pos[j] and upper[j] ~= 0) then
            local dj = 0
            for k = 1, K do
                dj = dj + w[k] * d[k][j]
            end
            local score = at_upper[j] and dj or -dj
            if (score > best_score) then
                if (bland) then
                    return j
                end
                best, best_score = j, score
            end
        end
    end
    st.work = st.work + st.N * K
    return best
end

---@return integer? row, number t, boolean to_upper
local function ratio_test(st, alpha, q, dir, limit)
    local beta, basis, upper = st.beta, st.basis, st.upper
    local bland = st.degenerate_run > BLAND_AFTER
    local best = limit
    local r, r_to_upper, r_abs = nil, false, 0
    for i, a in pairs(alpha) do
        local ad = a * dir
        local ratio, to_upper
        if (ad > PIVOT_TOL) then
            ratio, to_upper = beta[i] / ad, false
        elseif (ad < -PIVOT_TOL) then
            local ub = upper[basis[i]]
            if (ub) then
                ratio, to_upper = (ub - beta[i]) / -ad, true
            end
        end
        if (ratio) then
            if (ratio < 0) then
                ratio = 0
            end
            local aa = ad < 0 and -ad or ad
            local take = false
            if (r == nil) then
                take = ratio < best
            elseif (ratio < best - TIE_TOL) then
                take = true
            elseif (ratio <= best + TIE_TOL) then
                if (bland) then
                    take = basis[i] < basis[r]
                else
                    take = aa > r_abs
                end
            end
            if (take) then
                r, r_to_upper, r_abs = i, to_upper, aa
                if (ratio < best) then
                    best = ratio
                end
            end
        end
    end
    return r, best, r_to_upper
end

--- Move nonbasic variable q in direction dir by at most `limit`, pivoting if a basic
--- variable hits a bound first.
---@param raise boolean? true when called from lp.raise_upper: q stays "at upper" on a full move
---@return boolean ok, boolean? pivoted
local pivot_row, start_value, pivot
local function move(st, q, dir, limit, raise)
    local alpha = ftran(st, column(st, q))
    local r, t, to_upper = ratio_test(st, alpha, q, dir, limit)
    if (t == INF) then
        st.status = "unbounded"
        return false
    end

    st.iterations = st.iterations + 1
    if (t <= TIE_TOL) then
        st.degenerate_run = st.degenerate_run + 1
    else
        st.degenerate_run = 0
    end

    local beta = st.beta
    if (t > 0) then
        local delta = dir * t
        for i, a in pairs(alpha) do
            beta[i] = beta[i] - a * delta
        end
    end

    if (not r) then
        -- bound flip, basis unchanged
        if (not raise) then
            if (st.at_upper[q]) then
                st.at_upper[q] = nil
            else
                st.at_upper[q] = true
            end
        end
        return true, false
    end

    pivot(st, q, r, alpha, pivot_row(st, r), start_value(st, q) + dir * t, to_upper)
    return true, true
end

--- alpha_rj = (e_r^T B^-1) . [A | I]_j for every column j
pivot_row = function(st, r)
    local n = st.n
    local rho = btran(st, { [r] = 1 })
    local arow = {}
    local rowA = st.rowA
    local work = 0
    for i, ri in pairs(rho) do
        local js = n + i
        arow[js] = (arow[js] or 0) + ri
        for j, a in pairs(rowA[i]) do
            arow[j] = (arow[j] or 0) + ri * a
            work = work + 1
        end
    end
    st.work = st.work + work
    return arow
end

--- Current value of nonbasic column q.
start_value = function(st, q)
    return st.at_upper[q] and st.upper[q] or 0
end

--- Column q enters the basis in row r at value `value`; the leaving column goes to its upper
--- bound when to_upper, else to 0.
pivot = function(st, q, r, alpha, arow, value, to_upper)
    local beta = st.beta
    local p = alpha[r]
    local leave = st.basis[r]
    local pos = st.pos
    for k = 1, st.K do
        local dk = st.d[k]
        local dq = dk[q]
        if (dq ~= 0) then
            local f = dq / p
            for j, a in pairs(arow) do
                if (not pos[j]) then
                    dk[j] = dk[j] - f * a
                end
            end
            dk[leave] = -f
        end
        dk[q] = 0
    end

    add_eta(st.etas, alpha, r)
    beta[r] = value
    st.basis[r] = q
    pos[q] = r
    pos[leave] = nil
    st.at_upper[q] = nil
    st.at_upper[leave] = to_upper or nil

    st.since = st.since + 1
    if (st.since >= REINVERT_EVERY) then
        if (not reinvert(st)) then
            -- numerically singular: keep the update etas and try again later
            st.since = 0
        end
    end
end

--- Dual simplex, for bounds changed with lp.set_bound: the basis stays, so the reduced costs
--- stay optimal, but basic variables may now be outside their bounds. Each iteration takes the
--- one furthest outside, moves it onto that bound and lets the nonbasic column enter that keeps
--- the reduced costs closest to optimal (Harris' two-pass ratio test). Columns made usable since
--- (dual infeasible) count as ratio 0; the primal iterations after this fix them.

---@return integer? row
---@return boolean to_upper
local function choose_leaving(st)
    local beta, basis, upper = st.beta, st.basis, st.upper
    local r, worst, to_upper = nil, 0, false
    for i = 1, st.m do
        local v = beta[i]
        if (v < -FEAS_TOL) then
            if (-v > worst) then
                r, worst, to_upper = i, -v, false
            end
        else
            local ub = upper[basis[i]]
            if (ub and v > ub + FEAS_TOL * (1 + ub)) then
                if (v - ub > worst) then
                    r, worst, to_upper = i, v - ub, true
                end
            end
        end
    end
    st.work = st.work + st.m
    return r, to_upper
end

--- One dual iteration. False when it can't go on (st.status says why); st.dual is cleared once
--- every basic variable is within its bounds.
---@return boolean
local function dual_iterate(st)
    local r, to_upper = choose_leaving(st)
    if (not r) then
        st.dual = nil
        return true
    end
    st.dual_iterations = (st.dual_iterations or 0) + 1
    if (st.dual_iterations > 20 * st.m + 1000) then
        st.status = "dual_failed"
        return false
    end
    local arow = pivot_row(st, r)
    local pos, at_upper, upper, d, w, K = st.pos, st.at_upper, st.upper, st.d, st.weights, st.K
    -- the leaving variable rises to 0 (s = -1) or falls to its upper bound (s = 1): an entering
    -- column moving in its direction dir must have sign(alpha * dir) = s
    local s = to_upper and 1 or -1
    local tol = st.opt_tol or OPT_TOL
    local cands, nc = {}, 0
    local bound = INF
    for j, a in pairs(arow) do
        if (not pos[j] and upper[j] ~= 0) then
            local dir = at_upper[j] and -1 or 1
            local ad = a * dir * s
            if (ad > DUAL_PIVOT_TOL) then
                local dj = 0
                for k = 1, K do
                    dj = dj + w[k] * d[k][j]
                end
                -- optimal reduced cost: dir * dj >= 0
                local slackness = dir * dj
                if (slackness < 0) then
                    slackness = 0
                end
                nc = nc + 1
                cands[nc] = j
                local rb = (slackness + tol) / ad
                if (rb < bound) then
                    bound = rb
                end
            end
        end
    end
    st.work = st.work + nc * (K + 1)
    local q, q_abs = nil, 0
    for t = 1, nc do
        local j = cands[t]
        local a = arow[j]
        local dir = at_upper[j] and -1 or 1
        local ad = a * dir * s
        local dj = 0
        for k = 1, K do
            dj = dj + w[k] * d[k][j]
        end
        local slackness = dir * dj
        if (slackness < 0) then
            slackness = 0
        end
        if (slackness / ad <= bound and ad > q_abs) then
            q, q_abs = j, ad
        end
    end
    if (not q) then
        -- no column can bring it back: the new bounds have no solution
        st.status = "dual_failed"
        return false
    end
    local alpha = ftran(st, column(st, q))
    local p = alpha[r]
    if (not p or (p < 0 and -p or p) < DUAL_PIVOT_TOL) then
        st.status = "dual_failed"
        return false
    end
    local target = to_upper and upper[st.basis[r]] or 0
    local dx = (st.beta[r] - target) / p
    local beta = st.beta
    for i, a in pairs(alpha) do
        beta[i] = beta[i] - a * dx
    end
    st.iterations = st.iterations + 1
    pivot(st, q, r, alpha, arow, start_value(st, q) + dx, to_upper)
    return true
end

--- One simplex iteration. Returns false when finished.
local function iterate(st)
    if (st.iterations >= st.max_iterations) then
        st.status = "iteration_limit"
        return false
    end

    local q = choose_entering(st)
    if (not q) then
        st.status = "optimal"
        return false
    end

    local dir = st.at_upper[q] and -1 or 1
    return (move(st, q, dir, st.upper[q] or INF))
end

--- Advance the solver by roughly `budget` units of work.
---@param skip_final boolean? skip the final refactorization (for throwaway what-if copies)
---@return boolean finished
function lp.step(st, budget, skip_final)
    if (st.status ~= "running") then
        return true
    end
    local stop_at = st.work + budget
    while (st.work < stop_at) do
        if (st.dual) then
            if (not dual_iterate(st)) then
                return true
            end
        elseif (not iterate(st)) then
            if (not skip_final) then
                -- final clean factorization so values and reduced costs are accurate
                reinvert(st)
            end
            return true
        end
    end
    return false
end

--- Set the upper bound of variable j, keeping the current solution feasible, and mark the
--- state as running again so lp.step re-optimizes from there. False when the current solution
--- can't be kept (solve again from scratch).
---@return boolean
function lp.set_upper(st, j, value)
    local u = st.upper[j]
    if (u == nil or value < 0) then
        return false
    end
    if (u == 0 and value > 0) then
        -- a locked column (upper bound 0) is kept out of the row index and its reduced costs
        -- aren't maintained: put it back and recompute them. The rows are copied first, since a
        -- fork (lp.fork) shares them with the state it came from.
        for i, a in pairs(st.A[j]) do
            local row = {}
            for k, v in pairs(st.rowA[i]) do
                row[k] = v
            end
            row[j] = a
            st.rowA[i] = row
        end
        -- at 0 either way; as "at its lower bound" it stays at 0 under the new bound
        st.at_upper[j] = nil
        st.upper[j] = value
        refresh(st)
    elseif (value > u) then
        if (not st.pos[j] and st.at_upper[j]) then
            -- push j up from its old bound as far as feasibility allows
            if (not move(st, j, 1, value - u, true)) then
                return false
            end
        end
    elseif (value < u) then
        local r = st.pos[j]
        if (r and st.beta[r] > value) then
            return false
        end
    end
    st.upper[j] = value
    st.status = "running"
    st.iterations = 0
    st.degenerate_run = 0
    return true
end

--- Sets the upper bound of column j (nil: none, 0: locked) on a solved state, whatever the
--- current solution: lp.commit_bounds then makes the changes take effect, and lp.step brings
--- the solution back within its bounds (dual simplex) before it optimizes again. For many
--- changes at once, such as a new scan of a factory that changed a little.
---@param j integer a column (not a slack)
---@param value number?
function lp.set_bound(st, j, value)
    local u = st.upper[j]
    if (u == 0 and value ~= 0) then
        -- unlock: into the row index (copied first: a fork may share the rows)
        for i, a in pairs(st.A[j]) do
            local row = {}
            for k, v in pairs(st.rowA[i]) do
                row[k] = v
            end
            row[j] = a
            st.rowA[i] = row
        end
        st.at_upper[j] = nil
    end
    if (not st.pos[j] and st.at_upper[j] and (value == nil or value == 0)) then
        -- nonbasic at an upper bound that is gone: at 0 instead
        st.at_upper[j] = nil
    end
    st.upper[j] = value
end

--- After lp.set_bound: the basic values and reduced costs again from the basis, and the dual
--- simplex armed for lp.step.
function lp.commit_bounds(st)
    refresh(st)
    lp.update_tolerance(st)
    st.status = "running"
    st.iterations = 0
    st.degenerate_run = 0
    st.dual = true
    st.dual_iterations = 0
end

--- Lower the upper bound of j to `value`, handing what j loses to k, a column identical to j
--- (same coefficients): the solution itself doesn't change, and lp.step re-optimizes from there
--- (pulling k back down when nothing rewards it). False when that isn't possible.
---@return boolean
function lp.lower_into(st, j, value, k)
    local u = st.upper[j]
    if (u == nil or value < 0 or value >= u) then
        return lp.set_upper(st, j, value)
    end
    local r = st.pos[j]
    if (r) then
        if (st.beta[r] <= value) then
            st.upper[j] = value
            st.status = "running"
            st.iterations = 0
            return true
        end
        -- basic above the new bound: make it nonbasic at its current value with a pivot that
        -- moves nothing (another column enters at its own current value)
        local arow = pivot_row(st, r)
        local q, best = nil, PIVOT_TOL
        for c, a in pairs(arow) do
            local aa = a < 0 and -a or a
            if (aa > best and not st.pos[c] and st.upper[c] ~= 0) then
                q, best = c, aa
            end
        end
        if (not q) then
            return false
        end
        u = st.beta[r]
        st.upper[j] = u
        pivot(st, q, r, ftran(st, column(st, q)), arow, start_value(st, q), true)
    end
    if (st.pos[k]) then
        return false
    end
    if (st.at_upper[j]) then
        local delta = u - value
        local vk = start_value(st, k)
        st.upper[k] = vk + delta
        st.at_upper[k] = true
    end
    st.upper[j] = value
    st.status = "running"
    st.iterations = 0
    st.degenerate_run = 0
    return true
end

--- Adds columns to a state, solved or not, locked at 0 (lp.set_upper opens one), so the
--- solution stays as it is. They go after the other columns: the slacks' indices (n + i) move
--- up, nothing else does. Must not be called on a state with forks still in use.
---@param cols table<integer, number>[] row -> coefficient, per new column
---@param costs number[] their cost, for the first cost component (0 in the others)
---@return integer[] indices of the new columns
function lp.extend(st, cols, costs)
    local k = #cols
    local n, N = st.n, st.N
    local new = {}
    if (k == 0) then
        return new
    end
    local function map(j)
        return j > n and j + k or j
    end
    for t = 1, k do
        local c = {}
        for i, a in pairs(cols[t]) do
            if (a ~= 0) then
                c[i] = a
            end
        end
        st.A[n + t] = c
        new[t] = n + t
    end
    local upper, at_upper, pos = {}, {}, {}
    for j, u in pairs(st.upper) do
        upper[map(j)] = u
    end
    for t = 1, k do
        upper[n + t] = 0
    end
    for j, v in pairs(st.at_upper) do
        at_upper[map(j)] = v
    end
    for j, r in pairs(st.pos) do
        pos[map(j)] = r
    end
    local basis = {}
    for i, j in pairs(st.basis) do
        basis[i] = map(j)
    end
    st.upper, st.at_upper, st.pos, st.basis = upper, at_upper, pos, basis
    for kk = 1, st.K do
        local c, d = {}, {}
        local ck, dk = st.c[kk], st.d[kk]
        for j = 1, N do
            c[map(j)] = ck[j]
            d[map(j)] = dk[j]
        end
        for t = 1, k do
            c[n + t] = kk == 1 and (costs[t] or 0) or 0
            -- not kept up to date while locked: lp.set_upper recomputes it
            d[n + t] = 0
        end
        st.c[kk], st.d[kk] = c, d
    end
    st.n, st.N = n + k, N + k
    st.max_iterations = 30 * st.N + 1000
    return new
end

local function copy(t)
    local r = {}
    for k, v in pairs(t) do
        r[k] = v
    end
    return r
end

--- A copy of a solved state to try a change on (a what-if), without touching the original.
--- Only what the solver changes is copied: the matrix, costs and factorization entries are
--- shared, so this is far cheaper than a deep copy. Neither copy may be changed by anything but
--- lp.step, lp.set_upper and lp.lower_into.
---@return table
function lp.fork(st)
    local f = {}
    for k, v in pairs(st) do
        f[k] = v
    end
    f.beta = copy(st.beta)
    f.basis = copy(st.basis)
    f.pos = copy(st.pos)
    f.at_upper = copy(st.at_upper)
    f.upper = copy(st.upper)
    f.etas = copy(st.etas)
    f.rowA = copy(st.rowA)
    local d = {}
    for k = 1, st.K do
        d[k] = copy(st.d[k])
    end
    f.d = d
    return f
end

---@return number
function lp.value(st, j)
    local r = st.pos[j]
    if (r) then
        return st.beta[r]
    end
    if (st.at_upper[j]) then
        return st.upper[j]
    end
    return 0
end

return lp
