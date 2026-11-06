-- Editor tweaks: hide scenery and apply saved world edits (hidden objects, source
-- geometry, base-world teleporters) with each layout. Editing happens in Creative.
local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
local Objects=dofile(dir..'objects.lua')
local Instances=dofile(dir..'instances.lua')
local Geometry=dofile(dir..'geometry.lua')
local Portals=dofile(dir..'portals.lua')
local Store=dofile(dir..'store.lua')
return function(R,C,U)
    local files=Store.new(R)
    for _,path in ipairs(dofile(dir..'leaf_assets.lua')) do R.native.load_asset(path) end
    -- World edits never touch a vanilla session.
    local hooks=C.scoped(function(s) return s.mode~='vanilla' end)
    local state,host_value,return_data,load_path
    local autosave=false
    local saved={}
    local function log(fmt,...) R.log('BaseWorldPlus',fmt,...) end
    local function world_id(world) return world:GetFName():ToString() end
    local function lookup(path) return R.valid(StaticFindObject(path)) end
    local row_key=Store.key

    local function restore_one(s,key)
        local r=s.originals[key];if not r then return end
        if R.valid(r.object) then
            if r.row.kind=='actor' then Objects.restore(r.original)
            elseif r.row.kind=='component' then Objects.componentSet(r.original,false)
            else Instances.set(r.object,r.row,false) end
        end
        s.originals[key]=nil
    end
    local function clear()
        if not state then return end
        local s=state;state=nil
        for key in pairs(s.originals) do restore_one(s,key) end
        for _,original in pairs(s.portal_originals) do if R.valid(original.actor) then Portals.restore(original) end end
        for _,actor in ipairs(s.spawned) do if R.valid(actor) then R.native.destroy(actor) end end
    end
    local function apply_one(s,key,row)
        if s.originals[key] then return end
        local object=lookup(row.path)
        if not object then log('Object missing: %s',row.path);return end
        local original
        if row.kind=='actor' then
            if not Objects.allowed(object) then log('Object is not scenery: %s',row.path);return end
            original=Objects.capture(object)
        elseif row.kind=='component' then
            object=Objects.component(object,row.component)
            if not object then log('Component missing: %s %s',row.path,row.component);return end
            original=Objects.componentCapture(object)
        end
        s.originals[key]={row=row,object=object,original=original}
        if row.kind=='actor' then Objects.hide(original);log('Scenery hidden: %s',object:GetFullName())
        elseif row.kind=='component' then Objects.componentSet(original,true)
        else Instances.set(object,row,true) end
    end
    -- Guests receive the edits through Core's transport.
    local function publish()
        if state and state.host then C.net.publish('bwp.world',{layout=state.layout,data=state.data,views=state.views}) end
    end
    local function replace(info,data,views)
        clear()
        local s={world=info.world,layout=info.layout_id,host=info.host,data=data,originals={},undo={},
            spawned={},portal_originals={},views=views or {},is_playtest=info.is_playtest,selection=nil,list={}}
        state=s
        local count=0;for _ in pairs(data.hidden) do count=count+1 end
        log('Apply world=%s host=%s hidden=%d geometry=%d',data.world,tostring(info.host),count,data.geometry and #data.geometry.actors or 0)
        for key,row in pairs(data.hidden) do apply_one(s,key,row) end
        Geometry.restore(R,s,function() return state==s end,function()
            Portals.apply(R,s,lookup,function(path)
                local row={kind='actor',path=path};local key=row_key(row)
                if not s.originals[key] then apply_one(s,key,row) end
            end,function() return state==s end,publish)
        end)
    end
    -- The host edits the world in Creative, outside Playtest.
    local function ensure_edit()
        local c=C.session()
        if c.role=='client' or c.mode~='creative' or c.is_playtest then return end
        if not R.valid(c.world) or not R.valid(c.pc) then return end
        if state and state.unread then return end
        if not state then
            replace({world=c.world,layout_id='',host=true,is_playtest=false},
                {version=1,world=world_id(c.world),hidden={},portals={}})
        end
        return state,c.pc
    end
    local function edit(row,hidden)
        local s=state;local key=row_key(row)
        local previous=s.data.hidden[key]
        if hidden and previous or not hidden and not previous then return end
        s.undo[#s.undo+1]={key=key,before=previous}
        if hidden then s.data.hidden[key]=row;apply_one(s,key,row)
        else s.data.hidden[key]=nil;restore_one(s,key) end
        publish()
    end
    local undo
    undo=function()
        local s=state;local last=table.remove(s.undo)
        if not last then return end
        if last.group then
            for i=#last.group,1,-1 do s.undo[#s.undo+1]=last.group[i];undo() end
            return
        end
        if last.before then s.data.hidden[last.key]=last.before;apply_one(s,last.key,last.before)
        else s.data.hidden[last.key]=nil;restore_one(s,last.key) end
        publish()
    end

    -- Nearest scenery actors and foliage instances, nearest first.
    local function inventory(limit)
        local list={};local pc=C.session().pc
        local origin=pc.PlayerCameraManager:GetCameraLocation()
        local function add(row,position)
            local dx,dy,dz=position.X-origin.X,position.Y-origin.Y,position.Z-origin.Z
            list[#list+1]={row=row,distance=dx*dx+dy*dy+dz*dz}
        end
        for _,class in ipairs(Objects.classes) do for _,a in ipairs(R.find_all(class)) do
            if a:HasAnyFlags(0x80000) then add(Objects.row(a),a:K2_GetActorLocation()) end
        end end
        for _,c in ipairs(R.find_all('/Script/Engine.InstancedStaticMeshComponent')) do
            if c:HasAnyFlags(0x80000) then
                for index=0,c:GetInstanceCount()-1 do
                    add(Instances.row(c,index,Objects.path(c)),Instances.transform(c,index,true).Translation)
                end
            end
        end
        table.sort(list,function(a,b) return a.distance<b.distance end)
        local rows={}
        for i=1,math.min(#list,limit) do rows[i]=list[i].row end
        return rows
    end
    -- The object under the crosshair: a foliage instance, a scenery actor, or one
    -- component of any other placed actor. Foliage without collision is ray-tested.
    local function pick(pc)
        local camera=pc.PlayerCameraManager
        local origin=camera:GetCameraLocation();local rotation=camera:GetCameraRotation()
        local pitch,yaw=math.rad(rotation.Pitch),math.rad(rotation.Yaw)
        local ray={X=math.cos(pitch)*math.cos(yaw),Y=math.cos(pitch)*math.sin(yaw),Z=math.sin(pitch)}
        local finish={X=origin.X+ray.X*50000,Y=origin.Y+ray.Y*50000,Z=origin.Z+ray.Z*50000}
        local hit={};local colour={R=0,G=0,B=0,A=0}
        local blocked=StaticFindObject('/Script/Engine.Default__KismetSystemLibrary'):LineTraceSingle(
            pc,origin,finish,0,true,{},0,hit,true,colour,colour,0)
        local best=blocked and hit.Distance or 50000;local row
        if blocked then
            -- FHitResult.Component is reflected as FWeakObjectPtr.
            local c=R.valid(hit.Component:Get())
            local a=c and R.valid(c:GetOwner())
            if a and a:HasAnyFlags(0x80000) then
                if c:IsA('/Script/Engine.InstancedStaticMeshComponent') and hit.Item>=0 then row=Instances.row(c,hit.Item,Objects.path(c))
                elseif Objects.allowed(a) then row=Objects.row(a)
                else row=Objects.componentRow(a,c) end
            end
        end
        for _,c in ipairs(R.find_all('/Script/Engine.InstancedStaticMeshComponent')) do
            if c:HasAnyFlags(0x80000) then
                local mesh=R.valid(c.StaticMesh)
                if mesh and Instances.supported(Objects.path(mesh)) then
                    for i=0,c:GetInstanceCount()-1 do
                        local candidate={mesh=Objects.path(mesh),worldTransform=Instances.transform(c,i,true)}
                        local distance=Instances.ray(candidate,origin,ray,best)
                        if distance then best=distance;row=Instances.row(c,i,Objects.path(c)) end
                    end
                end
            end
        end
        return row
    end
    -- A row from the last list, by number or name.
    local function named(text)
        local index=tonumber(text)
        if index then return state.list[index] end
        for _,row in ipairs(state.list) do
            if Objects.label(row):lower()==text:lower() or row.path:match('PersistentLevel%.(.+)$')==text then return row end
        end
    end
    local function feedback(s)
        local label=s.selection and Objects.label(s.selection) or 'No eligible object under the crosshair'
        C.session().gi.IngameUIManager.GameMessagesWidget:AddGameMessage(
            FText((s.aim and 'Aim ON: ' or 'Aim OFF: ')..label..' · Insert hides · PageUp undoes'),FText(''),12)
    end
    local function reply(text) U.message('World edits',text) end
    local help='Home: select aimed object · Insert: hide it · PageUp: undo\n'
        ..'/hide near [N] — nearest scenery, lights and sounds\n/hide list — hidden objects\n'
        ..'/hide NUMBER or NAME — hide from the last list\n/hide show NUMBER or NAME\n/hide undo · /hide clear confirm · /hide status'
    -- /hide: for objects that are hard to aim at, such as sounds or large effects.
    local function hide_command(args)
        local s,pc=ensure_edit()
        if not s then
            reply('Use Creative as the host, outside Playtest.')
            return
        end
        local action=args[1] or 'help'
        if tonumber(action) then table.insert(args,1,'hide');action='hide' end
        if action=='status' then
            local count=0;for _ in pairs(s.data.hidden) do count=count+1 end
            local layoutPath=s.path or C.session().gm.LoadedLayoutFullPath
            layoutPath=type(layoutPath)=='string' and layoutPath or layoutPath:ToString()
            reply(count..' hidden objects.\n'..(layoutPath~='' and 'Layout: '..layoutPath or 'Map not saved yet.')..'\nSave the map to keep changes.')
        elseif action=='clear' then
            if args[2]~='confirm' then reply('Use /hide clear confirm to restore all hidden scenery.');return end
            local start=#s.undo
            local rows={}
            for _,row in pairs(s.data.hidden) do rows[#rows+1]=row end
            for _,row in ipairs(rows) do edit(row,false) end
            local steps={};while #s.undo>start do table.insert(steps,1,table.remove(s.undo)) end
            if #steps>0 then s.undo[#s.undo+1]={group=steps} end
            reply('Scenery restored. Save the map to keep it.')
        elseif action=='near' or action=='list' then
            local rows={}
            if action=='list' then
                for _,row in pairs(s.data.hidden) do rows[#rows+1]=row end
                table.sort(rows,function(a,b) return Objects.label(a)<Objects.label(b) end)
            else
                local limit=args[2] and tonumber(args[2]) or 10
                if not limit or limit%1~=0 or limit<1 or limit>50 then reply('Use /hide near [1..50], default 10.');return end
                rows=inventory(limit)
            end
            s.list=rows;local text={}
            for i,row in ipairs(rows) do text[i]=i..'. '..Objects.label(row)..(s.data.hidden[row_key(row)] and ' [hidden]' or '') end
            reply((action=='list' and 'Hidden objects: ' or 'Nearest scenery: ')..#rows..'\n'..table.concat(text,'\n'))
        elseif action=='undo' then undo()
        elseif action=='hide' or action=='show' then
            local row=args[2] and named(table.concat(args,' ',2)) or s.selection or pick(pc)
            if row then edit(row,action=='hide') else reply('Aim at an object or choose one from /hide near.') end
        else
            local row=named(table.concat(args,' '))
            if row then edit(row,true) else reply(help) end
        end
    end
    local commands={hide=hide_command}
    for name,fn in pairs(commands) do
        RegisterConsoleCommandHandler(name,function(_,args) R.next_frame(function() fn(args) end);return true end)
    end
    R.post('/Game/Blueprints/UserInterface/B_IngameUIManager.B_IngameUIManager_C:ParseChatCommand',function(self,text)
        local value=type(text)=='string' and text or text:ToString()
        local words={};for word in value:gmatch('%S+') do words[#words+1]=word end
        local command=(table.remove(words,1) or ''):gsub('^/',''):lower()
        local fn=commands[command];if fn then fn(words) end
    end)
    R.key('bwp.select','Home',function()
        local s,pc=ensure_edit()
        if not s then return end
        s.aim=not s.aim
        s.selection=pick(pc)
        feedback(s)
    end)
    R.key('bwp.hide','Insert',function()
        local s,pc=ensure_edit()
        if not s then return end
        local row=pick(pc)
        if not row then return end
        edit(row,true)
        s.selection=row
        if s.aim then feedback(s) end
    end)
    R.key('bwp.undo','PageUp',function() if ensure_edit() then undo() end end)

    hooks.on('layout_loaded',function(info)
        if not R.valid(info.world) then return end
        if not info.host then
            local value=host_value
            if value and value.layout==info.layout_id and value.data.world==world_id(info.world) then
                replace(info,value.data,value.views)
            else clear() end
            return
        end
        local data=return_data
        local path=load_path;load_path=nil
        if not path and state and state.layout==info.layout_id then path=state.path end
        if not path and info.is_creative then
            local value=C.session().gm.LoadedLayoutFullPath
            path=type(value)=='string' and value or value:ToString()
        end
        if not data and (path=='' or info.layout_id=='') then data={version=1,world=world_id(info.world),hidden={},portals={}} end
        if not data then
            local name=world_id(info.world)
            local ok,result=pcall(function() assert(path,'layout filename unavailable');return files.read(path,name) end)
            if not ok then
                clear();state={world=info.world,layout=info.layout_id,host=true,unread=true,originals={},portal_originals={},spawned={}}
                C.net.publish('bwp.world',false)
                log('World edits could not be read: %s',result)
                reply('Some saved world edits could not be read. Existing files will be preserved.')
                return
            end
            data=result
            if not data then return end
        end
        replace(info,data);state.path=path
    end)
    local function client_world()
        local c=C.session()
        if c.role~='client' then return end
        if c.mode=='vanilla' then
            host_value=nil
            clear()
            return
        end
        local value=host_value
        if not value then clear();return end
        if not c.world or world_id(c.world)~=value.data.world then return end
        if state and state.data==value.data then return end
        replace({world=c.world,layout_id=value.layout,host=false,is_playtest=c.is_playtest},value.data,value.views)
    end
    C.net.watch('bwp.world',function(value)
        if value then Store.validate(value.data) end
        host_value=value
        client_world()
    end)
    hooks.post(Portals.CLASS..':ReceiveBeginPlay',function(actor)
        if not state or state.host then return end
        if actor:GetWorld():GetAddress()==state.world:GetAddress() then Portals.present(state,actor,Objects.path(actor)) end
    end)
    R.native.on_load(function(event)
        if event.complete and event.success then load_path=event.target_path end
    end)
    hooks.on('layout_saved',function(info)
        if state and state.host and not autosave then state.layout=info.layout_id;publish() end
    end)
    -- Saving a layout writes its world edits next to it, from a snapshot taken at save start.
    R.native.on_save(function(event)
        if event.phase=='entry' then
            autosave=event.autosave
            if state and state.host then saved[event.serial]={data=state.data and files.copy(state.data),unread=state.unread} end
        elseif event.complete then
            local snapshot=saved[event.serial];saved[event.serial]=nil
            if not event.success or not snapshot then return end
            if snapshot.unread then reply('The layout saved, but unread world edits were preserved.');return end
            local ok,why=files.save(event.target_path,snapshot.data)
            if not ok then
                log('World edits save failed: %s',why)
                reply('The layout saved, but its world edits could not be saved.')
                return
            end
            if not event.autosave and state then state.path=event.target_path end
        end
    end)
    local creative='/Game/Blueprints/Gamemodes/CreativeMode/B_CreativeGameMode.B_CreativeGameMode_C:'
    hooks.pre(creative..'EndPlayTest',function() if state then return_data=state.data end end)
    hooks.post(creative..'EndPlayTest',function()
        if return_data then
            local c=C.session()
            replace({world=c.world,layout_id=state and state.layout or '',host=c.role~='client',is_playtest=false},return_data)
        end
        return_data=nil
    end)
    hooks.post(creative..'NewLayout',function()
        clear();C.net.publish('bwp.world',false)
    end)
    -- Entering a vanilla session removes every edit.
    C.on_session(function(c)
        if c.mode=='vanilla' then host_value=nil;clear() end
        client_world()
    end)
    R.on('world_end',function() state,host_value,return_data,saved=nil,nil,nil,{} end)
end
