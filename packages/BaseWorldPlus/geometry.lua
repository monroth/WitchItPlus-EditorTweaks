local M={}
function M.groups(rows)
    local by,root={},{}
    for i,r in ipairs(rows) do by[r.source],root[i]=i,i end
    local function find(i)
        while root[i]~=i do
            root[i]=root[root[i]]
            i=root[i]
        end
        return i
    end
    local function link(i,path)local j=by[path];if j then root[find(i)]=find(j)end end
    for i,r in ipairs(rows)do
        if r.parent then link(i,r.parent.source)end
        for _,path in ipairs(r.references or {})do link(i,path)end
    end
    local result,index={},{}
    for i,r in ipairs(rows) do
        local k=find(i)
        if not index[k] then
            index[k]=#result+1
            result[#result+1]={}
        end
        local group=result[index[k]]
        group[#group+1]=r
    end
    return result
end
function M.restore(R,s,current,done)
    local d=s.data.geometry
    if not d or #d.actors==0 then done();return end
    local groups=M.groups(d.actors);local at=1
    local function step()
        if not current()then return end
        local group=groups[at]
        if not group then done();return end
        local rows={}
        for _,row in ipairs(group)do
            if s.host or row.role=='local'then rows[#rows+1]=row end
        end
        if #rows>0 then
            local actors,why=R.native.source_actors(rows,s.world,d.states)
            assert(actors,why or 'source actor group could not be restored')
            for _,a in ipairs(actors)do s.spawned[#s.spawned+1]=a end
        end
        at=at+1;R.next_frame(step)
    end
    step()
end
return M
