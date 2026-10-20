-- Explicit per-operation Native service facade. It never wraps a UObject or
-- replaces a global helper. The caller supplies its immutable held lease.
local M={}
function M.new(X,held)
 local owner=assert(X.api or FAPP_API,'geometry runtime owner required')
 local Core=assert(owner.shared('Core'),'Core required')
 local G=assert(Core.guarded_native,'Core guarded_native required').new(owner,X.Lifetime,held)
 local N={}
 function N.current() return G.current() end
 function N.check() assert(G.current(),'geometry Native owner retired') end
 local function result(fn,...)
  N.check();local value=fn(...);N.check();return value
 end
 function N.read(o,k) return result(G.read,o,k) end
 local actorMutations={SetActorHiddenInGame=true,SetActorEnableCollision=true,SetVisibility=true,SetHiddenInGame=true,Activate=true,Deactivate=true,Play=true,Stop=true}
 function N.call(o,k,...)
  if actorMutations[k]then
   N.check();local broker=Core.actor_edit_claims
   assert(broker,'shared actor mutation reservations unavailable')
   local token,scope=owner.map_document.capture();assert(token and owner.map_document.current(token),'geometry document unavailable')
   local actor=o
   if G.call(o,'IsA','/Script/Engine.Actor')~=true then actor=G.call(o,'GetOwner')end
   N.check();assert(G.valid(actor),'geometry actor unavailable');N.check()
   local full=G.call(actor,'GetFullName');N.check();local path=type(full)=='string'and full:match('^%S+ (.+)$')
   assert(path and not broker.blocked(scope,path),'actor reserved by another editor')
   N.check();assert(owner.map_document.current(token),'geometry document retired')
  end
  return result(G.call,o,k,...)
 end
 function N.valid(o) return result(G.valid,o) end
 function N.key(o) return result(G.key,o) end
 function N.worldKey(o) return result(G.worldKey,o) end
 function N.authority(o) return result(G.authority,o) end
 function N.sameWorld(a,b) return result(G.sameWorld,a,b) end
 function N.text(o) return result(G.text,o) or '' end
 function N.unwrap(o) return result(G.unwrap,o) end
 function N.pipeKey(o)
  local address=N.call(o,'GetAddress');local name=N.call(o,'GetFullName')
  if tonumber(address) and tonumber(address)>0 and type(name)=='string' and name~='' then return tostring(address)..'|'..name end
 end
 function N.copy(o,fields)
  if not o then return end
  local v={}
  for _,k in ipairs(fields or {'X','Y','Z'}) do
   local n=N.read(o,k);if type(n)~='number' or n~=n or math.abs(n)==math.huge then return end;v[k]=n
  end
  return v
 end
 function N.object(path)
  N.check();local o=StaticFindObject(path);N.check()
  assert(N.valid(o),'native object not loaded: '..path);return o
 end
 function N.bridge()
  return setmetatable({call=N.call,read=N.read,text=N.text,get=N.unwrap,
   H=setmetatable({valid=N.valid,authority=N.authority},{__index=X.H}),
   same=function(a,b) return a~=nil and b~=nil and N.key(a)==N.key(b) end,
   current=N.current,check=N.check},{__index=X})
 end
 return N
end
return M
