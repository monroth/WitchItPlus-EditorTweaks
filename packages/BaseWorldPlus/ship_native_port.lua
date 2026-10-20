-- Only scalar values and host-owned opaque tokens cross the Native boundary.
local M={contract='ShipParts.Native/v1'}
function M.new(api,T,raw,store,owner_current)
 assert(type(raw)=='table' and raw.contract=='ShipParts.Native.Raw/v2','exact ship Native adapter required')
 for _,n in ipairs({'capture','current','resolve','read','set_visible','set_hidden','set_collision','inventory','release','trace_ready','pick'}) do
  assert(type(raw[n])=='function','missing ship Native method '..n)
 end
 local D=assert(api.map_document,'authoritative document service required')
 assert(type(D.cleanup_current)=='function','document cleanup_current owner delta required')
 local currentOwner=assert(owner_current or api.owner_current,'exact API owner guard required')
 local function backend()
  if type(store)=='function' then return store() end
  return store
 end
 local contexts,handles={},setmetatable({},{__mode='k'});local alive=true
 local P={contract=M.contract}
 local function own(ctx)
  local r=alive and contexts[ctx]
  return r and rawget(ctx,'world')==r.world and rawget(ctx,'layout')==r.layout and not getmetatable(ctx) and r or false
 end
 local function current(ctx,mode)
  local r=own(ctx);if not r then return false end
  local fn=mode=='cleanup' and (D.rollback_current or D.cleanup_current) or D.current
  return fn(r.document)==true and currentOwner(mode)==true and own(ctx)==r
 end
 local function invoke(name,...)
  return api.native_access('ShipParts.Native.'..name,raw[name],...)
 end
 function P.capture(policy)
  assert(policy==T,'exact cooked topology required');local document,v=D.capture()
  assert(document and v and D.current(document)==true and v.document_kind=='saved' and v.role=='host'
   and v.world=='PirateIsland' and type(v.name)=='string' and #v.name>0,'saved authoritative PirateIsland layout required')
  local ctx={world=T.world,layout=v.name};local r={document=document,context=ctx,world=T.world,layout=v.name,view=v};contexts[ctx]=r
  local function guard(mode) return current(ctx,mode) end
  local token,why=invoke('capture',guard,ctx.world,ctx.layout,v.document_generation)
  assert(current(ctx,'edit') and type(token)=='userdata',why or 'native capture unavailable');r.token=token;return ctx
 end
 function P.logical_current(ctx,mode)return current(ctx,mode or 'edit')==true end
 local function bind(r)
  local s=backend()
  if r.hooks and s and s.bind_session and r.bound~=s then
   if r.unbind then r.unbind()end;r.unbind=s.bind_session(r.hooks);r.bound=s
  end
 end
 function P.bind_session(ctx,hooks)local r=assert(own(ctx));assert(not r.hooks or r.hooks==hooks);r.hooks=hooks;bind(r);return function()if r.hooks==hooks then if r.unbind then r.unbind()end;r.unbind=nil;r.bound=nil;r.hooks=nil end end end
 function P.current(ctx,mode)
  assert(mode=='edit' or mode=='cleanup','invalid ship lane');local r=own(ctx)
  if not r or not current(ctx,mode) or not r.token then return false end
  local yes=invoke('current',r.token,mode);return yes==true and current(ctx,mode) and own(ctx)==r
 end
 local function call(ctx,name,guard,...)
  local r=assert(own(ctx),'ship context retired');assert(type(guard)=='function' and guard()==true,'private ship scope retired')
  local mode=P.current(ctx,'edit') and 'edit' or 'cleanup';assert(P.current(ctx,mode),'ship document retired')
  local args=table.pack(...);args.n=args.n+1;args[args.n]=guard
  local value=table.pack(invoke(name,r.token,mode,table.unpack(args,1,args.n)))
  assert(own(ctx)==r and current(ctx,mode) and guard()==true,'ship scope retired during native call')
  assert(value[1]~=nil,value[2] or 'native component operation refused');return table.unpack(value,1,value.n)
 end
 function P.resolve(ctx,actor,component,expected,guard)
  if expected~=nil then assert(handles[expected]==ctx,'foreign/aliased native component ticket') end
  local token,f=call(ctx,'resolve',guard,actor,component,expected)
  assert(type(token)=='userdata' and type(f)=='table','native component receipt required')
  if expected then
   -- Host token userdata emissions need not be rawequal. Return the original
   -- canonical wrapper after native validates its exact id/incarnation.
   token=expected
  else handles[token]=ctx end
  return token,f
 end
 local function operation(name,h,guard,value)
  local ctx=assert(handles[h],'canonical ship component ticket required')
  if value==nil then return call(ctx,name,guard,h) end
  return call(ctx,name,guard,h,value)
 end
 function P.read(h,g) return operation('read',h,g) end
 function P.set_visible(h,v,g) assert(type(v)=='boolean');return operation('set_visible',h,g,v) end
 function P.set_hidden(h,v,g) assert(type(v)=='boolean');return operation('set_hidden',h,g,v) end
 function P.set_collision(h,v,g) assert(math.type(v)=='integer' and v>=0 and v<=5);return operation('set_collision',h,g,v) end
 function P.inventory(ctx,g)
  local rows=call(ctx,'inventory',g);assert(type(rows)=='table' and math.type(rows.count)=='integer' and rows.count>=0 and rows.count<=512)
  local out={};for i=1,rows.count do out[i]=assert(rows[tostring(i)],'missing native inventory row') end;return out
 end
 -- Exact native trace ingress is not supplied by this host contract. Lists still
 -- admit new component edits. Target refuses explicitly instead of actor fallback.
 function P.pick(ctx,g)
  assert(call(ctx,'trace_ready',g)==true,'exact native trace backend not ready')
  local hit=call(ctx,'pick',g);assert(type(hit)=='table' and type(hit.blocked)=='boolean','native trace result required')
  if hit.blocked then assert(hit.instance==-1 and type(hit.handle)=='userdata','exact native component receipt required');handles[hit.handle]=ctx end
  return hit
 end
 function P.trace_ready(ctx,g) return call(ctx,'trace_ready',g)==true end
 local function storage(ctx,g)
  local bound=backend();assert(bound and bound.contract=='Core.Native.ScalarStorage/v1' and bound.current()==true,'ship file storage backend unavailable')
  assert(P.current(ctx,'edit') and g()==true,'ship document retired');local r=assert(own(ctx))
  local document,v=D.capture();assert(document and v and D.current(document),'current document snapshot unavailable')
  assert(v.name==r.layout and v.world=='PirateIsland','storage document identity differs')
  local h=bound.capture(v,g);assert(P.current(ctx,'edit') and g()==true);return bound,h,v
 end
 function P.persist(ctx,text,revision,g)
  assert(type(text)=='string' and #text<=65536 and math.type(revision)=='integer' and revision>=0)
  local s,h,v=storage(ctx,g);local result=table.pack(pcall(s.write,h,text,revision,g));s.release(h)
  assert(result[1],result[2]);local receipt=result[2]
  assert(type(receipt)=='table' and receipt.contract=='Core.Native.ScalarStorage.Receipt/v1' and receipt.publication=='COMMITTED'
   and receipt.world==ctx.world and receipt.layout==ctx.layout and receipt.target_path==v.target_path
   and receipt.document_generation==v.document_generation and receipt.owner_generation==v.owner_generation
   and receipt.document_revision==v.revision and receipt.revision==revision and receipt.bytes==text,'exact file storage result required')
  assert(P.current(ctx,'edit') and g()==true);return receipt
 end
 function P.read_file(ctx,g)
  local s,h=storage(ctx,g);local result=table.pack(pcall(s.read,h,g));s.release(h);assert(result[1],result[2])
  assert(P.current(ctx,'edit') and g()==true);return result[2],result[3]
 end
 function P.file_applied()local s=backend();if s and s.applied then s.applied()end end
 function P.file_blocked()local s=backend();return s and s.blocked and s.blocked()end
 function P.file_error()local s=backend();return s and s.error and s.error()end
 function P.storage_ready()local s=backend();if s then for _,r in pairs(contexts)do bind(r)end end;return s and s.contract=='Core.Native.ScalarStorage/v1' and s.current()==true or false end
 function P.on_load(fn)assert(P.storage_ready(),'ship file observer unavailable');return assert(backend()).on_load(fn)end
 -- Native successful SaveAs advances only the same document generation. Renew
 -- the private scalar lease; canonical component receipts keep physical identity.
 function P.rebind(ctx)
  local r=assert(own(ctx));assert(P.current(ctx,'cleanup'),'old physical rollback scope unavailable')
  local token,v=D.capture();assert(token and v and D.current(token) and v.role=='host' and v.document_kind=='saved'
   and v.world=='PirateIsland' and v.owner_generation==r.view.owner_generation and v.document_generation==r.view.document_generation
   and v.world_key==r.view.world_key and v.world_generation==r.view.world_generation,'different physical/document owner requires cleanup')
  assert(currentOwner('edit'));local old=r.view;r.document=token;r.view=v;r.layout=v.name;ctx.layout=v.name;assert(P.current(ctx,'edit'))
  if r.hooks and r.hooks.retarget then r.hooks.retarget(old,v)end;return true
 end
 function P.release(ctx)
  local r=assert(own(ctx));assert(P.current(ctx,'cleanup'),'cleanup scope retired')
  assert(invoke('release',r.token,'cleanup')==true,'native originals not restored');if r.unbind then r.unbind()end;contexts[ctx]=nil
 end
 function P.abandon() for _,r in pairs(contexts)do if r.unbind then r.unbind()end end;alive=false;contexts={};handles=setmetatable({},{__mode='k'}) end
 return P
end
return M
