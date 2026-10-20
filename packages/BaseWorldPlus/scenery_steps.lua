-- One native operation per continuation. These checks preserve Core lifetime
-- semantics without repeating its entire owner/world walk in one queue step.
local M={}
function M.task(build)
 local queue,cursor={},1
 local function add(fn) queue[#queue+1]=fn end
 build(add)
 return function()
  local fn=queue[cursor]
  if not fn then return true end
  cursor=cursor+1;fn()
  return cursor>#queue
 end
end
function M.check(X,object,world,done,knownIdentity,guard)
 local epoch=X.Lifetime.epoch
 local identities={[object or false]=knownIdentity}
 local aborted,finished=false,false
 local complete=done
 done=function(...) if not finished then finished=true;complete(...) end end
 local step=M.task(function(add)
  local function call(o,k,args,thenDo)
   add(function()
    local key=identities[o]
    if key and (X.Lifetime.retired or {})[key] then aborted=true;done(false);return end
    thenDo(X.call(o,k,table.unpack(args or {})))
   end)
  end
  local rawValid
  local function raw(o,cb)
   if not o then cb(false);return end
   if type(o)=='userdata' then
    add(function()
     local kind=X.call(o,'type')
     if not ({UObject=true,AActor=true,UWorld=true,UClass=true,UFunction=true,UStruct=true,UEnum=true,UDataTable=true})[kind] then cb(false)
     else rawValid(o,cb) end
    end)
   elseif type(o)=='table' then rawValid(o,cb) else cb(false) end
  end
  -- Local to each task: no validity result survives another mutation/travel.
  rawValid=function(o,cb)
   call(o,'IsValid',nil,function(valid)
    if valid~=true then cb(false);return end
    local flags={}
    for _,name in ipairs({'PendingKill','Unreachable','Garbage'}) do
     local flag=type(EInternalObjectFlags)=='table' and EInternalObjectFlags[name]
     if flag then flags[#flags+1]={'HasAnyInternalFlags',flag} end
    end
    for _,name in ipairs({'RF_BeginDestroyed','RF_FinishDestroyed','BeginDestroyed','FinishDestroyed'}) do
     local flag=type(EObjectFlags)=='table' and EObjectFlags[name]
     if flag then flags[#flags+1]={'HasAnyFlags',flag} end
    end
    local i=0
    local function nextFlag()
     i=i+1;local f=flags[i]
     if f then call(o,f[1],{f[2]},function(bad) if bad==true then cb(false) else nextFlag() end end)
     else call(o,'IsA',{'/Script/Engine.Actor'},function(actor)
      if actor==true then call(o,'IsActorBeingDestroyed',nil,function(bad) cb(bad~=true) end) else cb(true) end
     end) end
    end
    nextFlag()
   end)
  end
  local function identity(o,cb)
   call(o,'GetAddress',nil,function(address)
    call(o,'GetFullName',nil,function(full)
     local key=address and full and tostring(address)..':'..full
     if o==object and knownIdentity and key~=knownIdentity then aborted=true;done(false);return end
     identities[o]=key;cb(key,full)
    end)
   end)
  end
  local function present(o,cb)
   if not o then cb(false);return end
   call(o,'GetAddress',nil,function(address)
    if address~=nil then cb(tonumber(address)~=0) else raw(o,cb) end
   end)
  end
  raw(object,function(valid)
   if not valid then done(false);return end
   identity(object,function(key,full)
    if key and (X.Lifetime.retired or {})[key] then done(false);return end
    local function checkWorld()
     call(object,'GetWorld',nil,function(w)
      raw(w,function(ok)
       if not ok then
        if world then done(false);return end
        if full and full:find('Default__',1,true) then done(true,full,key);return end
        local classes={'/Script/Engine.Actor','/Script/Engine.ActorComponent','/Script/UMG.UserWidget'}
        local i=0
        local function nextClass()
         i=i+1
         if not classes[i] then done(true,full,key);return end
         call(object,'IsA',{classes[i]},function(is) if is==true then done(false) else nextClass() end end)
        end
        nextClass();return
       end
       identity(w,function(wkey)
        done(wkey~=nil and (not world or wkey==world) and (not X.Lifetime.world or wkey==X.Lifetime.world),full,key,wkey)
       end)
      end)
     end)
    end
    local seen,depth={},0
    local function owner(parent)
     present(parent,function(exists)
      if not exists then checkWorld();return end
      raw(parent,function(ok)
       if not ok then done(false);return end
       identity(parent,function(pkey)
        if pkey and (X.Lifetime.retired or {})[pkey] then done(false);return end
        depth=depth+1
        if not pkey or seen[pkey] or depth>=8 then checkWorld();return end
        seen[pkey]=true;call(parent,'GetOuter',nil,owner)
       end)
      end)
     end)
    end
    call(object,'IsA',{'/Script/Engine.Actor'},function(actor)
     local function outer() call(object,'GetOuter',nil,owner) end
     if actor==true then call(object,'GetOwner',nil,function(parent)
      present(parent,function(exists) if exists then owner(parent) else outer() end end)
     end) else outer() end
    end)
   end)
  end)
 end)
 return function()
  if X.Lifetime.transition or X.Lifetime.epoch~=epoch then aborted=true;done(false) end
  if aborted then return true end
  if guard then guard() end
  local complete=step()
  if guard then guard() end
  return complete
 end
end
return M
