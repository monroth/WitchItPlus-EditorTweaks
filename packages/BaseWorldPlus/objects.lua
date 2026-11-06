-- What can be hidden and how: whole scenery actors, single components of any placed
-- actor, and single foliage instances (instances.lua).
local M={}
M.classes={'/Script/Engine.StaticMeshActor','/Script/Niagara.NiagaraActor','/Script/Engine.Emitter',
    '/Script/Engine.PointLight','/Script/Engine.SpotLight','/Script/Engine.RectLight','/Script/Engine.AmbientSound'}
for _,n in ipairs({'01','02','03','04','05','07'})do
    M.classes[#M.classes+1]='/Game/Environment/Island/B_Palm'..n..'.B_Palm'..n..'_C'
end
local effectFields={NiagaraActor=true,Emitter=true,PointLight=true,SpotLight=true,RectLight=true,AmbientSound=true}
local function kind(o) return o:GetFullName():match('^(%S+)') end
function M.path(o) return o:GetFullName():match('^%S+ (.+)$'):gsub('UEDPIE_%d+_','') end
-- Native arrays arrive either as TArray (ForEach) or, from function results, as Lua tables.
function M.values(a)
    local out={}
    if a.ForEach then a:ForEach(function(_,v) out[#out+1]=v:get() end)
    else for i,v in ipairs(a) do out[i]=v:get() end end
    return out
end
-- Scenery actors are hidden whole; any other placed actor is hidden one component at a time.
function M.allowed(a)
    local k=kind(a)
    return k=='StaticMeshActor' or effectFields[k]~=nil or k:match('^B_Palm0[123457]_C$')~=nil
end
function M.row(a) return {kind='actor',path=M.path(a)} end
function M.componentRow(a,c) return {kind='component',path=M.path(a),component=c:GetFName():ToString()} end
function M.component(actor,name)
    for _,c in ipairs(M.values(actor:K2_GetComponentsByClass(StaticFindObject('/Script/Engine.PrimitiveComponent')))) do
        if c:GetFName():ToString()==name then return c end
    end
end
local function title(name)
    return name:gsub('^SM_',''):gsub('^NS_',''):gsub('^BP_',''):gsub('^B_',''):gsub('(%l)(%u)','%1 %2'):gsub('_',' ')
end
function M.label(row)
    if row.kind=='instance' then return title(row.mesh:match('%.([^%.]+)$'))..' ['..row.index..']' end
    local actor=title(row.path:match('PersistentLevel%.(.+)$') or row.path)
    if row.kind=='component' then return actor..' · '..row.component end
    return actor
end
function M.capture(a)
    local s={actor=a,hidden=a.bHidden,collision=a.bActorEnableCollision,effects={}}
    local seen={}
    local function visit(c)
        local path=M.path(c)
        if seen[path] then return end
        seen[path]=true
        local r={component=c}
        if c:IsA('/Script/Engine.AudioComponent') then r.volume=c.VolumeMultiplier
        elseif c:IsA('/Script/Engine.LightComponent') then r.visible=c.bVisible
        elseif c:IsA('/Script/Engine.ParticleSystemComponent') or c:IsA('/Script/Niagara.NiagaraComponent') then
            r.visible=c.bVisible;r.active=c:IsActive()
        end
        if r.volume~=nil or r.visible~=nil then s.effects[#s.effects+1]=r end
        for _,child in ipairs(M.values(c.AttachChildren)) do visit(child) end
    end
    visit(a.RootComponent)
    return s
end
function M.hide(s)
    s.actor:SetActorHiddenInGame(true);s.actor:SetActorEnableCollision(false)
    for _,r in ipairs(s.effects) do local c=r.component
        if r.active~=nil then c:Deactivate() end
        if r.visible~=nil then c:SetVisibility(false,false) end
        if r.volume~=nil then c:SetVolumeMultiplier(0) end
    end
end
function M.restore(s)
    for _,r in ipairs(s.effects) do local c=r.component
        if r.volume~=nil then c:SetVolumeMultiplier(r.volume) end
        if r.visible~=nil then c:SetVisibility(r.visible,false) end
        if r.active then c:Activate(false) end
    end
    s.actor:SetActorHiddenInGame(s.hidden);s.actor:SetActorEnableCollision(s.collision)
end
function M.componentCapture(c)
    return {component=c,visible=c.bVisible,hidden=c.bHiddenInGame,collision=c.BodyInstance.CollisionEnabled}
end
function M.componentSet(s,hide)
    local c=s.component
    c:SetVisibility(not hide and s.visible,false)
    c:SetHiddenInGame(hide or s.hidden,false)
    c:SetCollisionEnabled(hide and 0 or s.collision)
end
return M
