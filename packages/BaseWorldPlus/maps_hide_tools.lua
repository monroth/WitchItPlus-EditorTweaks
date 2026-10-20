-- Pure geometry + user interface for the suppression backend. No polling when off.
local M={}
local function vector(p)
    if not p then return end
    for _,k in ipairs({'X','Y','Z'}) do
        local v=p[k]; if type(v)~='number' or v~=v or math.abs(v)==math.huge then return end
    end
    return {X=p.X,Y=p.Y,Z=p.Z}
end
M.vector=vector
function M.nearest(records,origin,n)
    local rows={}
    for key,r in pairs(records) do
        if r.position then
            local p=r.position
            rows[#rows+1]={key=key,record=r,distance=math.sqrt((p.X-origin.X)^2+(p.Y-origin.Y)^2+(p.Z-origin.Z)^2)}
        end
    end
    table.sort(rows,function(a,b) if a.distance~=b.distance then return a.distance<b.distance end return a.key<b.key end)
    while #rows>n do table.remove(rows) end
    return rows
end
function M.direction(p,origin,yaw)
    local angle=(math.deg(math.atan(p.Y-origin.Y,p.X-origin.X))-yaw+180)%360-180
    return (math.abs(angle)<=45 and 'ahead' or (math.abs(angle)>=135 and 'behind' or (angle>0 and 'right' or 'left')))..
        string.format(', height %+.1f m',(p.Z-origin.Z)/100)
end
function M.rayBox(origin,ray,center,extent,limit)
    local lo,hi=0,limit
    for _,k in ipairs({'X','Y','Z'}) do
        local delta=center[k]-origin[k]
        if math.abs(ray[k])<1e-9 then
            if math.abs(delta)>extent[k] then return end
        else
            local a,b=(delta-extent[k])/ray[k],(delta+extent[k])/ray[k]
            if a>b then a,b=b,a end
            lo,hi=math.max(lo,a),math.min(hi,b)
            if lo>hi then return end
        end
    end
    return lo
end
function M.init(X,backend)
    local api={}; local aiming=false
    local target,announced,nextPick,cache,cacheState,cacheEpoch,byAddress
    local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
    local clock=assert(X.clock,'Core event clock required')
    local function reply(s) (X.reply or function(_,msg) X.log('Hide',msg) end)('Hide',s) end
    local function notice(s) (X.notice or X.reply or function(_,msg) X.log('Hide',msg) end)('Hide',s) end
    -- Aim tracking stays non-modal; explicit command results use the dialog.
    local function say(s) if aiming then notice(s) else reply(s) end end -- hotkeys never steal input with a modal
    -- The aimed object blinks (local SetActorHiddenInGame) so the player sees what
    -- Insert would hide. Restored on every target change, edit, aim off and reset.
    local function identity(actor,N)
        local key=N.key(actor)
        if key then return key,key:match('^([^:]+):') end
    end
    local blink
    local clearAim
    local function unblink(s,retry)
        local b=blink;if not b then return true end
        if X.Lifetime.transition or b.epoch~=X.Lifetime.epoch then blink=nil;return true end
        if b.running or b.cleanup_pending and not retry then return false,'hide blink '..tostring(b.identity)..': '..tostring(b.error or 'restoration already running') end
        if (X.Lifetime.retired or {})[b.identity] then blink=nil;return true end
        b.running=true
        local ok,err=pcall(function()
            local N=backend.nativeOwner(b.state,true,b.actor,b.identity,b.class,nil,b.admission)
            N.call(b.actor,'SetActorHiddenInGame',b.original)
            assert(N.read(b.actor,'bHidden')==b.original,'blink visibility restoration refused')
        end)
        b.running=nil
        if X.Lifetime.transition or b.epoch~=X.Lifetime.epoch then blink=nil;return true end
        if not ok then b.cleanup_pending=true;b.error=err;return false,'hide blink '..tostring(b.identity)..': '..tostring(err) end
        if blink==b then blink=nil end
        return true
    end
    local function view(s,N)
        N=N or backend.nativeOwner(s,false)
        for id,pc in pairs(X.Registry.buckets.B_CreativePlayerController_C or {}) do
            local md=(X.Registry.metadata.B_CreativePlayerController_C or {})[id]
            if md and md.world==s.world and not (X.Lifetime.retired or {})[id]
                and N.valid(pc) and N.sameWorld(pc,s.gm) and N.call(pc,'IsLocalPlayerController')==true then
                local camera=N.read(pc,'PlayerCameraManager')
                local origin,rotation
                if N.valid(camera) then
                    origin=N.copy(N.call(camera,'GetCameraLocation'))
                    rotation=N.copy(N.call(camera,'GetCameraRotation'),{'Yaw','Pitch','Roll'})
                end
                if not origin then
                    local pawn=N.call(pc,'K2_GetPawn')
                    if N.valid(pawn) then origin=N.copy(N.call(pawn,'K2_GetActorLocation')) end
                    rotation=N.copy(N.call(pc,'GetControlRotation'),{'Yaw','Pitch','Roll'})
                end
                if origin and rotation then
                    local y,p=math.rad(rotation.Yaw),math.rad(rotation.Pitch)
                    return {pc=pc,N=N,origin=origin,yaw=rotation.Yaw,ray={X=math.cos(p)*math.cos(y),Y=math.cos(p)*math.sin(y),Z=math.sin(p)}}
                end
            end
        end
        error('local Creative player/camera unavailable')
    end
    local function actorOwner(s,r,parent)
        return backend.nativeOwner(s,false,r.actor,r.identity,r.class,parent and parent.current,r.admission)
    end
    local function name(s,r,parent)
        local N=actorOwner(s,r,parent);local a=r.actor
        local component=N.read(a,'StaticMeshComponent') or N.read(a,'NiagaraComponent') or N.read(a,'Decal')
        local asset=component and (N.read(component,'StaticMesh') or N.read(component,'Asset') or N.read(component,'DecalMaterial'))
        local label
        if N.valid(asset) then label=N.text(N.call(asset,'GetFName')) end
        return (label or r.name):sub(1,80)
    end
    local function records(s,bounds,parent)
        parent=parent or backend.nativeOwner(s,false)
        parent.check();local result=backend.inventory(s);parent.check()
        if X.work then return result end -- bounded Native metadata already prepared
        for _,r in pairs(result) do
            local N=actorOwner(s,r,parent)
            r.label=name(s,r,N)
            r.position=N.copy(N.call(r.actor,'K2_GetActorLocation'))
            if bounds then
                local geometry=dofile(dir..'scenery.lua')
                r.center,r.extent=geometry.bounds(N.bridge(),r.actor)
                if r.extent and (r.extent.X<0 or r.extent.Y<0 or r.extent.Z<0) then r.extent=nil end
            end
        end
        parent.check();return result
    end
    local function requireEditor(s)
        assert(s and backend.current(s),'geometry document retired')
        assert(s.creative,'Host only: open a Creative layout as host; guests cannot edit base objects')
        assert(not s.error,'Layout suppression needs reload: '..tostring(s.error))
        local N=backend.nativeOwner(s,false)
        assert(N.valid(s.gm),'Creative world changed; reopen the hide list')
        assert(N.authority(s.gm),'Host only: guests cannot edit base objects')
        local gp=N.object('/Script/Engine.Default__GameplayStatics')
        local gs=N.call(gp,'GetGameState',s.gm)
        assert(N.valid(gs) and N.read(gs,'IsPlayTestMode')==false,'Creative editing is unavailable during playtest')
        return N
    end
    local function line(s,row,index,v)
        local r=row.record
        return string.format('%d. %s (%s) — %.1f m, %s%s',index,r.label,r.name,row.distance/100,
            M.direction(r.position,v.origin,v.yaw),s.desired[row.key] and ' [hidden]' or '')
    end
    local function indexed(s,value)
        local index=tonumber(value)
        assert(index and index%1==0 and index>=1,'use a whole number from the last /hide near or /hide list')
        local key=s.lastList and s.lastList[index]
        assert(key,'number absent from last list; run /hide near or /hide list')
        assert(backend.inventory(s)[key],'listed object no longer exists; make a new list')
        return key
    end
    local function edit(s,key,hide)
        assert(unblink(s),'blink cleanup pending; use /hide cleanup before editing') -- before the backend snapshots original visibility
        assert(hide~=true or not s.desired[key],'object already hidden')
        assert(hide~=false or s.desired[key],'object is not hidden by BaseWorldPlus')
        local set={}; for k,v in pairs(s.desired) do set[k]=v end
        set[key]=hide or nil
        backend.change(s,set)
        say((hide and 'Hidden: ' or 'Restored: ')..backend.inventory(s)[key].name..'. Save the map to keep it.')
        target=nil
    end
    local function list(s,args,hidden,N)
        local count=tonumber(args[2] or '10')
        if not hidden then assert(count and count%1==0 and count>=1 and count<=50,'/hide near [1..50], default 10') end
        local v=view(s,N); local found=records(s,nil,v.N)
        if hidden then for key in pairs(found) do if not s.desired[key] then found[key]=nil end end end
        local rows=M.nearest(found,v.origin,hidden and 256 or count)
        s.lastList={}
        reply((hidden and 'Hidden scenery: ' or 'Nearest scenery: ')..#rows..'')
        for i,row in ipairs(rows) do s.lastList[i]=row.key; reply(line(s,row,i,v)) end
    end
    function api.run(s,args)
        local action=(args[1] or 'help'):lower()
        if s and action~='clear' then s.clearPending=nil end
        if action=='help' then
            reply('/hide near [10] | /hide <number> | /hide show <number> | /hide list | /hide undo')
            reply('/hide aim: aim mode on/off; /hide target hides crosshair target; /hide undo reverses it')
            reply('bwhide group/hidegroup/showgroup <names...>')
            reply('/hide clear | /hide save info | /hide cleanup')
            return
        end
        local N=requireEditor(s)
        if action=='cleanup' then
            assert(api.cleanup(s),'blink cleanup still pending')
            notice('Aim visibility restored; cleanup complete')
        elseif action=='near' or action=='list' then list(s,args,action=='list',N)
        elseif tonumber(action) then edit(s,indexed(s,action),true)
        elseif action=='show' then edit(s,indexed(s,args[2]),false)
        elseif action=='undo' then assert(unblink(s),'blink cleanup pending; use /hide cleanup'); backend.undo(s); say('Undone. Save the map to keep it.'); target=nil
        elseif action=='clear' then
            local now=clock.now()
            if s.clearPending and now<=s.clearPending then
                assert(unblink(s),'blink cleanup pending; use /hide cleanup'); backend.change(s,{}); s.clearPending=nil; target=nil; reply('Scenery restored. Save the map to keep it.')
            else s.clearPending=now+15; reply('Repeat /hide clear within 15 seconds to restore all hidden scenery') end
        elseif action=='save' and args[2]=='info' then
            local file=s.path and io.open(s.path,'rb');local saved=file~=nil;if file then file:close() end
            reply(saved and 'Map saved.' or 'Map not saved yet.')
            reply(s.dirty and 'Unsaved scenery changes. Save the map to keep them.' or 'Scenery changes saved.')
        elseif action=='aim' then
            assert(unblink(s),'blink cleanup pending; use /hide cleanup'); aiming=not aiming; target=nil; announced=false; nextPick=nil
            notice('Aim '..(aiming and 'ON: /hide target hides, /hide undo reverses, /hide aim turns off; collision target name/distance below.' or 'OFF'))
        elseif action=='target' or action=='_aimhide' then
            assert(aiming,'enable /hide aim first')
            local ok,err=pcall(api.pick,s)
            if not ok then api.reset(); notice('Aim stopped: '..tostring(err)); return end
            assert(target,'no hideable base object under crosshair')
            edit(s,target,true)
        else error('unknown /hide command; type /hide for help') end
    end
    local function resolve(object,N)
        if object==nil then return end
        if N.valid(object) then return object end
        -- UE4SS FHitResult OUT fields can be owned FWeakObjectPtr wrappers.
        local ok,actor=pcall(function() return N.call(object,'Get') end)
        if ok and N.valid(actor) then return actor end
    end
    local function trace(s,v)
        local N=v.N
        -- UE4SS reflects named numeric table fields into the by-value FVector /
        -- FLinearColor inputs. Keep start/end separate; OUT hit is a fresh table.
        local start=assert(vector(v.origin),'collision trace start is invalid')
        local finish=assert(vector({X=start.X+v.ray.X*50000,Y=start.Y+v.ray.Y*50000,Z=start.Z+v.ray.Z*50000}),
            'collision trace end is invalid')
        local colour={R=0,G=0,B=0,A=0}
        local hit={}
        local ok,blocked=pcall(function()
            local lib=N.object('/Script/Engine.Default__KismetSystemLibrary')
            return N.call(lib,'LineTraceSingle',v.pc,start,finish,0,true,{},0,hit,true,colour,colour,0)
        end)
        assert(ok,'collision trace unavailable: '..tostring(blocked))
        assert(type(blocked)=='boolean','collision trace returned a non-boolean result: '..tostring(blocked))
        if not blocked then return end -- Native miss is final; never select an AABB behind it.
        local actor=resolve(N.read(hit,'HitActor'),N) or resolve(N.read(hit,'Actor'),N)
        if not actor then
            local component=resolve(N.read(hit,'Component'),N)
            if component then
                local owned,owner=pcall(function() return N.call(component,'GetOwner') end)
                if owned then actor=resolve(owner,N) end
            end
        end
        assert(actor,'collision trace hit could not resolve Actor/HitActor/Component owner')
        assert(N.valid(actor) and N.sameWorld(actor,s.gm),'collision trace hit is stale or outside the Creative world')
        local distance=N.read(hit,'Distance')
        if type(distance)~='number' or distance~=distance or distance<0 or distance==math.huge then
            local pos=N.copy(N.call(actor,'K2_GetActorLocation'))
            assert(pos,'collision trace hit distance unavailable')
            distance=math.sqrt((pos.X-start.X)^2+(pos.Y-start.Y)^2+(pos.Z-start.Z)^2)
        end
        return actor,distance
    end
    function api.pick(s)
        if not aiming then return end
        assert(not blink or not blink.cleanup_pending,'blink cleanup pending; use /hide cleanup')
        local N=requireEditor(s)
        local v=view(s,N)
        -- Existing prepared records supply identities without an all-actor native
        -- walk. Each pick performs one trace and validates only the actual hit.
        if cacheState~=s or cacheEpoch~=X.Lifetime.epoch then
            cache=nil; byAddress=nil; cacheState=s; cacheEpoch=X.Lifetime.epoch
        end
        if not byAddress then
            v.N.check();cache=backend.inventory(s);v.N.check();byAddress={}
            for key,r in pairs(cache) do
                local id=r.identity
                local address=id and id:match('^([^:]+):')
                if not id and not X.work then id,address=identity(r.actor,actorOwner(s,r,v.N)) end
                assert(id and address,'collision inventory identity unavailable; reload the hide inventory')
                if not (X.Lifetime.retired or {})[id] then
                    assert(not byAddress[address],'collision inventory contains an ambiguous actor address')
                    byAddress[address]={key=key,identity=id,class=r.class}
                end
            end
        end
        local actor,distance=trace(s,v)
        local picked,entry,blocker
        if actor then
            local id,address=identity(actor,v.N)
            assert(id,'collision trace actor identity unavailable')
            entry=byAddress[address]
            if entry then
                assert(id==entry.identity,'collision trace actor identity changed; restart aim after the inventory settles')
                assert(not (X.Lifetime.retired or {})[id],'collision trace actor is retired')
                if not s.desired[entry.key] then picked=entry.key end
            else
                -- An ineligible collider (prop, player, foliage, etc.) occludes
                -- inventory actors behind it, exactly as in the old trace path.
                blocker=id:match('^[^:]+:(.*)$')
            end
        end
        if picked and not cache[picked].label then cache[picked].label=name(s,cache[picked],v.N) end
        if picked and (cache[picked].label..cache[picked].name):lower():find('terrain',1,true) then picked=nil end
        target=picked
        if picked~=announced then
            announced=picked
            assert(unblink(s),'blink cleanup pending; use /hide cleanup')
            if picked then
                local BN=actorOwner(s,cache[picked],v.N)
                local original=BN.read(actor,'bHidden')==true
                blink={actor=actor,key=picked,identity=entry.identity,class=entry.class,admission=cache[picked].admission,state=s,documentToken=s.documentToken,epoch=X.Lifetime.epoch,on=false,original=original}
                notice(string.format('Aim: %s (%s), %.1f m [collision]',cache[picked].label,cache[picked].name,(distance or 0)/100))
            else notice('Aim: no hideable base object'..(blocker and ' (hit '..blocker..')' or '')) end
        end
    end
    function api.tick(s,time)
        if not aiming then return end -- MUST precede all engine/context work
        if X.Lifetime.transition or not X.C.CreativeMaps or not s or not s.creative or s.error then api.reset(); return end
        local now=time or clock.now()
        if nextPick and now<nextPick then return end
        nextPick=now+.25
        local ok,err=pcall(api.pick,s)
        if not ok then api.reset(); notice('Aim stopped: '..tostring(err)); return end
        if blink and time>=(blink.next or 0) then
            local b=blink
            if b.running or b.cleanup_pending then return end
            b.running=true
            local ok,err=pcall(function()
                assert(backend.current(b.state) and b.state.documentToken==b.documentToken,'blink document retired')
                local N=backend.nativeOwner(b.state,false,b.actor,b.identity,b.class,nil,b.admission)
                b.on=not b.on;b.next=time+0.35
                N.call(b.actor,'SetActorHiddenInGame',b.on)
            end)
            b.running=nil
            if X.Lifetime.transition or b.epoch~=X.Lifetime.epoch then if blink==b then blink=nil end;return end
            if not ok then b.cleanup_pending=true;b.error=err;clearAim() end
        end
    end
    function api.key(action)
        if action~='aim' and not aiming then return end
        if backend.editable and not backend.editable() then return end
        backend.enqueue({action},true,true)
    end
    function api.active() return aiming end
    clearAim=function()
        aiming=false; target=nil; announced=nil; nextPick=nil; cache=nil; cacheState=nil; cacheEpoch=nil; byAddress=nil
    end
    function api.cleanup(s)
        local complete,why=unblink(s or cacheState,true)
        clearAim()
        return complete,why
    end
    function api.cleanupPending() return blink~=nil and blink.cleanup_pending==true end
    function api.reset()
        local complete,why=unblink(cacheState)
        clearAim()
        return complete,why
    end
    function api.abandon() blink=nil;clearAim() end
    if X.Lifetime.onReset then X.Lifetime.onReset(api.abandon) end
    return api
end
return M
