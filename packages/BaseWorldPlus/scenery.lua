-- Verified cooked B_BasePalm family; exact paths and owned component fields.
-- One definition supplies discovery, admission and bounds for every Island class.
local M={classes={'StaticMeshActor','NiagaraActor','Emitter','PointLight','SpotLight','RectLight','AmbientSound'},classPaths={}}
local palmFamily={
 {name='B_Palm01_C',path='/Game/Environment/Island/B_Palm01.B_Palm01_C',fields={'Palm'}},
 {name='B_Palm02_C',path='/Game/Environment/Island/B_Palm02.B_Palm02_C',fields={'Palm'}},
 {name='B_Palm03_C',path='/Game/Environment/Island/B_Palm03.B_Palm03_C',fields={'Palm'}},
 {name='B_Palm04_C',path='/Game/Environment/Island/B_Palm04.B_Palm04_C',fields={'Palm'}},
 {name='B_Palm05_C',path='/Game/Environment/Island/B_Palm05.B_Palm05_C',fields={'Palm'}},
 {name='B_Palm07_C',path='/Game/Environment/Island/B_Palm07.B_Palm07_C',fields={'Leafs','Trunk'}}
}
local palms={}
for _,definition in ipairs(palmFamily) do
 M.classes[#M.classes+1]=definition.name
 M.classPaths[definition.name]=definition.path
 palms[definition.name]=definition.fields
end
local components={NiagaraActor='NiagaraComponent',Emitter='ParticleSystemComponent',
 PointLight='LightComponent',SpotLight='LightComponent',RectLight='LightComponent',AmbientSound='AudioComponent'}
local allow={} for _,c in ipairs(M.classes) do allow[c]=true end
local function call(X,a,k,...)
 local args=table.pack(...);local ok,v=pcall(X.call,a,k,table.unpack(args,1,args.n))
 if X.check then X.check() end
 if ok then return v end
end
local function class(X,a)
 local c=call(X,a,'GetClass');local name=c and call(X,c,'GetFName')
 return name and X.text(name)
end
function M.eligible(X,a,full)
 local name=full and full:match('^(%S+)') or class(X,a)
 if not allow[name] then return false end
 if M.classPaths[name] and call(X,a,'IsA',M.classPaths[name])~=true then return false end
 -- Runtime-added components on an authored actor must not bring gameplay along.
 full=full or call(X,a,'GetFullName')
 if type(full)~='string' then return false end
 return not full:find('Default__',1,true)
end
function M.snapshot(X,a)
 local field=components[class(X,a)]; if not field then return {} end
 local c=X.read(a,field); assert(X.H.valid(c),'scenery component unavailable: '..field)
 local r={component=c,field=field}
 if field=='LightComponent' then
  r.visible=X.read(c,'bVisible'); assert(type(r.visible)=='boolean','light visibility unavailable')
 elseif field=='AudioComponent' then
  r.playing=call(X,c,'IsPlaying'); assert(type(r.playing)=='boolean','audio activity unavailable')
 else
  r.active=call(X,c,'IsActive'); assert(type(r.active)=='boolean','effect activity unavailable')
 end
 return r
end
function M.hide(X,a,r,guard)
 local c=r.component; if not c then return end
 if guard then guard() end
 if r.visible~=nil then X.call(c,'SetVisibility',false,false)
 elseif r.playing~=nil then X.call(c,'Stop')
 else X.call(c,'Deactivate') end
 if guard then guard() end
end
function M.restore(X,a,r,checked,guard)
 if not r or not r.component then return end
 local c=r.component; assert(checked or X.H.valid(c),'scenery component retired')
 if guard then guard() end
 if r.visible~=nil then X.call(c,'SetVisibility',r.visible,false)
 elseif r.playing~=nil then if r.playing then X.call(c,'Play',0) else X.call(c,'Stop') end
 elseif r.active then X.call(c,'Activate',false) else X.call(c,'Deactivate') end
 if guard then guard() end
end
M.componentFields=components
local function xyz(p,X)
 if not p then return end
 local r={}
 for _,k in ipairs({'X','Y','Z'}) do
  local v;if X then v=X.read(p,k) else v=p[k] end; if type(v)~='number' or v~=v or math.abs(v)==math.huge then return end
  r[k]=v
 end
 return r
end
function M.transform(origin,ext,p,scale,rot)
   local y,t,r=math.rad(rot.Yaw),math.rad(rot.Pitch),math.rad(rot.Roll)
   local cy,sy,ct,st,cr,sr=math.cos(y),math.sin(y),math.cos(t),math.sin(t),math.cos(r),math.sin(r)
   local matrix={{ct*cy,sr*st*cy-cr*sy,-cr*st*cy-sr*sy},
                 {ct*sy,sr*st*sy+cr*cy,-cr*st*sy+sr*cy},{st,-sr*ct,cr*ct}}
   local keys={'X','Y','Z'}; local center,extent={},{}
   for i,k in ipairs(keys) do
    center[k]=p[k]; extent[k]=0
    for j,q in ipairs(keys) do
     center[k]=center[k]+matrix[i][j]*origin[q]*scale[q]
     extent[k]=extent[k]+math.abs(matrix[i][j]*ext[q]*scale[q])
    end
   end
   return center,extent
end
function M.bounds(X,a)
 local fields=palms[class(X,a)]
 if fields then
  local rows={}
  for _,field in ipairs(fields) do
   local c=X.read(a,field)
   if not X.H.valid(c) or not X.same or not X.same(call(X,c,'GetOwner'),a) then return end
   local mesh=X.read(c,'StaticMesh');if not X.H.valid(mesh) then return end
   local b=call(X,mesh,'GetBounds');local origin=b and xyz(X.read(b,'Origin'),X);local ext=b and xyz(X.read(b,'BoxExtent'),X)
   local p=xyz(call(X,c,'K2_GetComponentLocation'),X);local scale=xyz(call(X,c,'K2_GetComponentScale'),X)
   local raw=call(X,c,'K2_GetComponentRotation');local rot
   if raw then rot={Yaw=X.read(raw,'Yaw'),Pitch=X.read(raw,'Pitch'),Roll=X.read(raw,'Roll')} end
   if not origin or not ext or not p or not scale or not rot then return end
   for _,k in ipairs({'Yaw','Pitch','Roll'}) do local v=rot[k]
    if type(v)~='number' or v~=v or math.abs(v)==math.huge then return end
   end
   for _,k in ipairs({'X','Y','Z'}) do if ext[k]<0 then return end end
   local center,extent=M.transform(origin,ext,p,scale,rot)
   rows[#rows+1]={center=center,extent=extent}
  end
  return M.unionBounds(rows)
 end
 -- Pure Lua geometry derived from native return structs, never passed back to UE.
 local c=X.read(a,'StaticMeshComponent')
 local mesh=c and X.read(c,'StaticMesh')
 if X.H.valid(mesh) then
  local b=call(X,mesh,'GetBounds'); local origin=b and xyz(X.read(b,'Origin'),X); local ext=b and xyz(X.read(b,'BoxExtent'),X)
  local p=xyz(call(X,c,'K2_GetComponentLocation'),X); local scale=xyz(call(X,c,'K2_GetComponentScale'),X)
  local raw=call(X,c,'K2_GetComponentRotation');local rot
   if raw then rot={Yaw=X.read(raw,'Yaw'),Pitch=X.read(raw,'Pitch'),Roll=X.read(raw,'Roll')} end
  if origin and ext and p and scale and rot and type(rot.Yaw)=='number' and type(rot.Pitch)=='number' and type(rot.Roll)=='number' then
   return M.transform(origin,ext,p,scale,rot)
  end
 end
 -- Small explicit bounds for effects/lights/audio; buildings with no native mesh
 -- bounds are selectable through the numbered near list, not a guessed giant box.
 if class(X,a)~='StaticMeshActor' then
  return xyz(call(X,a,'K2_GetActorLocation'),X),{X=100,Y=100,Z=100}
 end
end
function M.unionBounds(rows)
 local low,high={},{}
 for _,row in ipairs(rows) do
  local center,extent=xyz(row.center),xyz(row.extent)
  if not center or not extent then return end
  for _,k in ipairs({'X','Y','Z'}) do
   if extent[k]<0 then return end
   local a,b=center[k]-extent[k],center[k]+extent[k]
   low[k]=low[k] and math.min(low[k],a) or a;high[k]=high[k] and math.max(high[k],b) or b
  end
 end
 if not low.X then return end
 local center,extent={},{}
 for _,k in ipairs({'X','Y','Z'}) do center[k]=(low[k]+high[k])/2;extent[k]=(high[k]-low[k])/2 end
 if not xyz(center) or not xyz(extent) then return end
 return center,extent
end
local function palmMetadata(X,r,Steps,fields)
 local epoch=X.Lifetime.epoch
 local generation=WIR_RUNTIME and WIR_RUNTIME.world_generation
 local rows,tasks,identities={},{},{};local failed=false
 tasks[#tasks+1]=function() r.center=nil;r.extent=nil;r.label=r.name;r.metadata=nil;r.position=X.call(r.actor,'K2_GetActorLocation');return true end
 tasks[#tasks+1]=function() r.position=xyz(r.position,X);return true end
 for _,field in ipairs(fields) do
  local c,owner,owned,part
  tasks[#tasks+1]=function() c=X.read(r.actor,field);return true end
  tasks[#tasks+1]=X.work.defer(function()
   if not c then failed=true;return function() return true end end
   return Steps.check(X,c,X.Lifetime.world,function(valid,_,identity)
    if valid then identities[#identities+1]=identity else c=nil;failed=true end
   end)
  end)
  tasks[#tasks+1]=function() if c then owner=X.call(c,'GetOwner') end;return true end
  tasks[#tasks+1]=X.work.defer(function()
   if not owner then failed=true;return function() return true end end
   return Steps.check(X,owner,X.Lifetime.world,function(valid,_,identity)
    owned=valid and identity==r.identity;if not owned then failed=true end
   end)
  end)
  tasks[#tasks+1]=X.work.defer(function()
   if not owned then return function() return true end end
   -- Reuse the existing productive mesh pipeline, retaining its component/asset
   -- lifetime checks and one native operation per continuation.
   part={actor=r.actor,name=r.name,identity=r.identity,class='StaticMeshActor',meshComponent=c,strictBounds=true}
   return M.metadataSteps(X,part,Steps)
  end)
  tasks[#tasks+1]=function()
   if part and part.center and part.extent then rows[#rows+1]=part else failed=true end
   return true
  end
 end
 tasks[#tasks+1]=function()
  if not failed then r.center,r.extent=M.unionBounds(rows) end
  r.metadata=true;return true
 end
 local step=X.work.sequence(tasks)
 return function()
  if X.Lifetime.transition or X.Lifetime.epoch~=epoch
   or (WIR_RUNTIME and WIR_RUNTIME.world_generation)~=generation
   or (X.Lifetime.retired or {})[r.identity] then return true end
  for _,identity in ipairs(identities) do if (X.Lifetime.retired or {})[identity] then return true end end
  return step()
 end
end
-- Editor-only metadata, cached by the inventory for this world. Runtime saved
-- hides need identities/components, never mesh transforms or asset labels.
function M.metadataSteps(X,r,Steps)
 if palms[r.class] then return palmMetadata(X,r,Steps,palms[r.class]) end
 local c,asset,b,origin,ext,p,scale,rot,componentIdentity,assetIdentity
 local tasks={}
 local function add(fn) tasks[#tasks+1]=function()
  local retired=X.Lifetime.retired or {}
  if not X.Lifetime.transition and not (r.identity and retired[r.identity])
   and not (componentIdentity and retired[componentIdentity]) and not (assetIdentity and retired[assetIdentity]) then fn() end
  return true
 end end
 local function vector(get,set,fields)
  local values={}
  for _,k in ipairs(fields or {'X','Y','Z'}) do
   add(function() local src=get();values[k]=src and X.read(src,k) end)
  end
  add(function() set(values) end)
 end
 add(function() r.position=X.call(r.actor,'K2_GetActorLocation') end)
 vector(function() return r.position end,function(v) r.position=xyz(v) end)
 add(function() c=r.meshComponent or r.component end)
 tasks[#tasks+1]=X.work.defer(function()
  if not c then return function() return true end end
  return Steps.check(X,c,X.Lifetime.world,function(valid,_,id) if valid then componentIdentity=id else c=nil end end)
 end)
 add(function() if r.class=='StaticMeshActor' then asset=c and X.read(c,'StaticMesh')
  elseif r.class=='NiagaraActor' then asset=c and X.read(c,'Asset') end end)
 tasks[#tasks+1]=X.work.defer(function()
  if not asset then return function() return true end end
  return Steps.check(X,asset,nil,function(valid,_,id) if valid then assetIdentity=id else asset=nil end end)
 end)
 add(function() if asset then r.label=X.call(asset,'GetFName') end end)
 add(function() r.label=(r.label and X.text(r.label) or r.name):sub(1,80) end)
 add(function() if r.class=='StaticMeshActor' and asset then b=X.call(asset,'GetBounds') end end)
 add(function() origin=b and X.read(b,'Origin') end)
 add(function() ext=b and X.read(b,'BoxExtent') end)
 vector(function() return origin end,function(v) origin=xyz(v) end)
 vector(function() return ext end,function(v) ext=xyz(v) end)
 add(function() if b then p=X.call(c,'K2_GetComponentLocation') end end)
 vector(function() return p end,function(v) p=xyz(v) end)
 add(function() if b then scale=X.call(c,'K2_GetComponentScale') end end)
 vector(function() return scale end,function(v) scale=xyz(v) end)
 add(function() if b then rot=X.call(c,'K2_GetComponentRotation') end end)
 vector(function() return rot end,function(v) rot=v end,{'Yaw','Pitch','Roll'})
 add(function()
  if r.strictBounds then
   for _,k in ipairs({'X','Y','Z'}) do if ext and ext[k]<0 then ext=nil;break end end
   for _,k in ipairs({'Yaw','Pitch','Roll'}) do local v=rot and rot[k]
    if type(v)~='number' or v~=v or math.abs(v)==math.huge then rot=nil;break end
   end
  end
  if origin and ext and p and scale and rot and type(rot.Yaw)=='number' and type(rot.Pitch)=='number' and type(rot.Roll)=='number' then
   r.center,r.extent=M.transform(origin,ext,p,scale,rot)
  elseif r.class~='StaticMeshActor' then r.center,r.extent=r.position,{X=100,Y=100,Z=100} end
  r.metadata=true
 end)
 return X.work.sequence(tasks)
end
local statue={'SM_WomanStatue02B_26','SM_Crystal16','SM_Crystal17','SM_Crystal18','SM_Crystal19','SM_Crystal20','SM_Crystal21','SM_Crystal22','NS_DesertBLueCrystal','SM_RuneRayCircle3','SM_RuneRayCircle4','SM_RuneRayCircle5'}
function M.group(X,found,root,level,guard)
 local set={[root]=true};local byIdentity={}
 local function guarded(a,k)
  if guard then guard() end
  local value=call(X,a,k)
  if guard then guard() end
  return value
 end
 local function identity(a)
  local address=guarded(a,'GetAddress');local full=guarded(a,'GetFullName')
  if address and full then return tostring(address)..':'..full end
 end
 for key,r in pairs(found) do byIdentity[identity(r.actor)]=key end
 local function parent(r)
  local a=guarded(r.actor,'GetAttachParentActor');return a and identity(a)
 end
 -- Connected attachment component, restricted to the already-eligible inventory.
 local changed=true
 while changed do
  changed=false
  for key,r in pairs(found) do
   local p=byIdentity[parent(r)]
   if p and (set[key] or set[p]) then
    if not set[key] or not set[p] then changed=true; set[key]=true; set[p]=true end
   end
  end
 end
 if level=='DesertTown' then
  local names={}; for key,r in pairs(found) do names[r.name]=key end
  local member=false; for _,name in ipairs(statue) do if names[name]==root then member=true end end
  if member then for _,name in ipairs(statue) do assert(names[name],'statue group incomplete'); set[names[name]]=true end end
 end
 local rows={}; for key in pairs(set) do rows[#rows+1]=key end; table.sort(rows); return rows
end
return M
