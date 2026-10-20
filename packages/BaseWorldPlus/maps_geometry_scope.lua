-- Pure document/actor leases. No observer, Native lookup, timer or IO.
local M={}
function M.new(D,L,Registry,s)
 local S={}
 local function world()
  return not L.transition and L.epoch==s.epoch and (not L.world or L.world==s.world)
 end
 local function matches(v)
  return v and v.world==s.level and v.world_key==s.worldKey and v.core_epoch==(s.coreEpoch or s.epoch)
   and v.world_generation==s.worldGeneration and v.owner_generation==s.ownerGeneration
 end
 function S.edit()
  local token=s.documentToken
  if not world() or not token or not D.current(token) then return nil,'document_retired' end
  return {token=token,epoch=s.epoch,kind='edit'}
 end
 function S.cleanup()
  if not world() then return nil,'world_retired' end
  local token,v=D.capture()
  if not token or not matches(v) or not D.current(token) then return nil,'cleanup_pending' end
  -- This token grants rollback ONLY. Never replace the old edit/document token.
  return {token=token,epoch=s.epoch,kind='cleanup'}
 end
 function S.current(lease)
  return lease and lease.epoch==s.epoch and world() and D.current(lease.token) or false
 end
 function S.actor(lease,actor,identity,class,admission)
  if not S.current(lease) or not identity or (L.retired or {})[identity] then return false end
  local bucket=Registry.buckets and Registry.buckets[class]
  local metadata=Registry.metadata and Registry.metadata[class]
  -- Registry membership is admitted before any old/reused Native getter.
  return bucket and bucket[identity]==actor and metadata and metadata[identity]
   and metadata[identity].world==s.world and (not admission or metadata[identity]==admission.metadata or L.retirement_revision==admission.retirement_revision) or false
 end
 function S.admission(lease,actor,identity,class)
  if not S.actor(lease,actor,identity,class) then return end
  return {metadata=Registry.metadata[class][identity],retirement_revision=L.retirement_revision}
 end
 function S.check(lease)
  assert(S.current(lease),'geometry document retired')
 end
 function S.native(lease,fn,...)
  S.check(lease)
  local result=table.pack(fn(...))
  S.check(lease)
  return table.unpack(result,1,result.n)
 end
 function S.step(lease,fn)
  return function(...)
   if not S.current(lease) then return true end
   return S.native(lease,fn,...)
  end
 end
 return S
end
return M
