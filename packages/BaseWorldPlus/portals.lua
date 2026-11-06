local M={CLASS='/Game/Blueprints/StaticProps/B_TeleporterZone.B_TeleporterZone_C'}
local function scene(c,p)
    c.RelativeLocation={X=p.X,Y=p.Y,Z=p.Z}
    c.RelativeRotation={Pitch=0,Yaw=p.Yaw,Roll=0}
    c:SetAbsolute(false,false,false);c:SetAbsolute(true,true,false)
end
local function capture(a)
    local z=a.Zone;local t=a.TargetLocation
    local p=t.RelativeLocation;local r=t.RelativeRotation
    local e=z:GetUnscaledBoxExtent()
    return {actor=a,hidden=a.bHidden,collision=a.bActorEnableCollision,overlap=z:GetGenerateOverlapEvents(),
        zoneCollision=z.BodyInstance.CollisionEnabled,extent={X=e.X,Y=e.Y,Z=e.Z},
        target={location={X=p.X,Y=p.Y,Z=p.Z},rotation={Pitch=r.Pitch,Yaw=r.Yaw,Roll=r.Roll},
            locationAbsolute=t.bAbsoluteLocation,rotationAbsolute=t.bAbsoluteRotation,scaleAbsolute=t.bAbsoluteScale},effects=a.UseEffects,
        transferVelocity=a.TransferPropVelocity,velocity=a.ExitVelocityMultiplier}
end
function M.configure(a,row,destination,baseline)
    local z=a.Zone;z:SetGenerateOverlapEvents(false)
    scene(a.TargetLocation,destination)
    z:SetBoxExtent(row.extent,false)
    a.UseEffects=row.effects
    a.TransferPropVelocity=row.transferVelocity
    a.ExitVelocityMultiplier=row.velocity
    a:SetActorHiddenInGame(row.removed or(baseline and baseline.hidden)or false)
    local collision=true;local zoneCollision=1
    if baseline then collision=baseline.collision;zoneCollision=baseline.zoneCollision end
    a:SetActorEnableCollision(not row.removed and collision);z:SetCollisionEnabled(row.removed and 0 or zoneCollision)
end
function M.present(s,a,path)
    local view=s.views[path]
    if not view or s.portal_originals[path]then return end
    local original=capture(a)
    original.presentation=true
    s.portal_originals[path]=original
    local row=view.row;local z=a.Zone
    z:SetGenerateOverlapEvents(false);z:SetBoxExtent(row.extent,false)
    a.UseEffects=row.effects
    a.TransferPropVelocity=row.transferVelocity
    a.ExitVelocityMultiplier=row.velocity
    z:SetCollisionEnabled(row.removed and 0 or 1)
end
function M.restore(s)
    local a=s.actor;local z=a.Zone
    if s.presentation then
        z:SetGenerateOverlapEvents(false);z:SetBoxExtent(s.extent,false)
        a.UseEffects=s.effects
        a.TransferPropVelocity=s.transferVelocity
        a.ExitVelocityMultiplier=s.velocity
        z:SetCollisionEnabled(s.zoneCollision)
        z:SetGenerateOverlapEvents(s.overlap)
        return
    end
    z:SetGenerateOverlapEvents(false)
    local target=a.TargetLocation;local original=s.target
    target.RelativeLocation=original.location;target.RelativeRotation=original.rotation
    target:SetAbsolute(not original.locationAbsolute,not original.rotationAbsolute,original.scaleAbsolute)
    target:SetAbsolute(original.locationAbsolute,original.rotationAbsolute,original.scaleAbsolute)
    z:SetBoxExtent(s.extent,false)
    a.UseEffects=s.effects
    a.TransferPropVelocity=s.transferVelocity
    a.ExitVelocityMultiplier=s.velocity
    a:SetActorHiddenInGame(s.hidden);a:SetActorEnableCollision(s.collision)
    z:SetCollisionEnabled(s.zoneCollision);z:SetGenerateOverlapEvents(s.overlap)
end
function M.apply(R,s,lookup,hide_decoration,current,done)
    local rows=s.data.portals
    if not next(rows)then done();return end
    local wanted={}
    for _,r in pairs(rows)do for _,path in ipairs(r.decor)do
        if wanted[path]==nil then wanted[path]=r.removed else wanted[path]=wanted[path]and r.removed end
    end end
    for path,hidden in pairs(wanted)do if hidden then hide_decoration(path)end end
    if not s.host then
        for _,a in ipairs(R.find_all(M.CLASS))do
            M.present(s,a,a:GetFullName():match('^%S+ (.+)$'))
        end
        done();return
    end
    local function apply(class)
        if not current()then return end
        local actors={}
        for id,row in pairs(rows)do
            local a
            if row.baked then
                a=lookup(row.baked)
                if a then s.portal_originals[row.baked]=capture(a);a.Zone:SetGenerateOverlapEvents(false)end
            else
                a=R.native.spawn(class,s.world,row.entry,function(actor)
                    actor:SetActorEnableCollision(false)
                    actor:SetReplicates(true)
                    actor:SetReplicateMovement(true)
                    actor.bAlwaysRelevant=true
                end)
                assert(a,'portal could not be created');s.spawned[#s.spawned+1]=a
                scene(a.DefaultSceneRoot,row.entry);a.TargetLocation:SetIsReplicated(true)
            end
            if a then actors[id]=a end
        end
        for id,a in pairs(actors)do local row=rows[id]
            local dest=row.exit
            if row.link then
                local other=rows[row.link]
                if other then dest=other.entry
                else
                    local baked=lookup(row.link:sub(3));assert(baked,'linked portal is missing')
                    local p=baked:K2_GetActorLocation();local r=baked:K2_GetActorRotation()
                    dest={X=p.X,Y=p.Y,Z=p.Z,Yaw=r.Yaw}
                end
            end
            M.configure(a,row,dest,row.baked and s.portal_originals[row.baked])
            local path=a:GetFullName():match('^%S+ (.+)$')
            s.views[path]={row=row}
            if row.link and actors[row.link]then
                R.native.teleporter_exit(a,actors[row.link])
                if rows[row.link].link==id then R.native.teleporter_pair(a,actors[row.link])end
            end
        end
        for id,a in pairs(actors)do
            local original=rows[id].baked and s.portal_originals[rows[id].baked]
            a.Zone:SetGenerateOverlapEvents(not rows[id].removed and(not original or original.overlap));a:ForceNetUpdate()
        end
        done()
    end
    R.native.on_asset(M.CLASS,function(asset,why)assert(asset,why);apply(asset)end)
end
return M
