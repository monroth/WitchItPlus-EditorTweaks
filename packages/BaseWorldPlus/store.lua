local M={}
function M.key(row)
    return row.kind..':'..row.path..(row.component and '|'..row.component or '')..(row.index and '|'..row.index or '')
end
function M.validate(d)
    assert(d.version==1 and type(d.world)=='string'and type(d.hidden)=='table'and type(d.portals)=='table','unknown world edits file')
    local hidden={}
    for _,r in pairs(d.hidden)do
        assert(type(r.path)=='string'and r.path:match('^/Game/'),'invalid object path')
        assert(r.kind=='actor'or r.kind=='component'or r.kind=='instance','unknown object edit')
        if r.kind=='component'then assert(type(r.component)=='string','missing component name')end
        if r.kind=='instance'then
            assert(type(r.mesh)=='string'and math.type(r.index)=='integer'and r.index>=0,'invalid saved instance')
            for name,axes in pairs({Translation={'X','Y','Z'},Rotation={'X','Y','Z','W'},Scale3D={'X','Y','Z'}})do
                for _,axis in ipairs(axes)do assert(type(r.transform[name][axis])=='number','invalid saved transform')end
            end
        end
        hidden[M.key(r)]=r
    end
    d.hidden=hidden
    for id,r in pairs(d.portals)do
        assert(r.id==id and type(r.decor)=='table','invalid saved portal')
        for _,flag in ipairs({'removed','effects','transferVelocity'})do assert(type(r[flag])=='boolean','invalid portal flag')end
        for _,field in ipairs({'entry','exit','extent'})do
            for _,axis in ipairs({'X','Y','Z'})do
                local v=r[field][axis];assert(type(v)=='number'and v==v and math.abs(v)<1e9,'invalid portal coordinate')
            end
        end
        assert(type(r.entry.Yaw)=='number'and type(r.exit.Yaw)=='number'and type(r.velocity)=='number','invalid portal destination')
    end
    if d.geometry then
        local g=d.geometry
        assert(g.format=='FAPP_SOURCE_GEOMETRY'and g.version==3 and type(g.actors)=='table'and type(g.states)=='table','invalid source geometry')
        assert(g.binding.folder==d.world,'geometry world differs')
        for _,r in ipairs(g.actors)do
            assert(r.restore=='actor'and(r.role=='authority'or r.role=='local')and type(r.class)=='string','invalid source actor')
            assert(type(r.source)=='string'and type(g.states[r.state])=='table'and #r.transform==9,'incomplete source actor')
        end
    end
    return d
end
-- World edits with source geometry reach about 1 MB. The limit leaves room for the
-- teleporter views sent with them in one Core message of at most 4 MB.
local LIMIT=4194304-65536
-- World edits live next to a layout in <layout>.pl.bwp.json.
function M.new(R)
    local function decode(bytes) return R.json.decode(bytes,LIMIT) end
    local N=R.native
    local S={}
    function S.copy(d) return decode(R.json.encode(d,LIMIT)) end
    function S.read(path,world)
        local bytes,why=N.file_read(path..'.bwp.json')
        assert(not why,why)
        if not bytes then return {version=1,world=world,hidden={},portals={}} end
        local d=M.validate(decode(bytes))
        -- A layout of another map reports its load before the travel: the new world reads it.
        if d.world==world then return d end
    end
    function S.save(path,d)
        local copy=S.copy(d)
        if copy.geometry then
            local folder,name=path:gsub('\\','/'):match('/([^/]+)/([^/]+)%.pl$')
            copy.geometry.binding.folder=folder;copy.geometry.binding.name=name
        end
        return N.file_write(path..'.bwp.json',R.json.encode(copy,LIMIT))
    end
    return S
end
return M
