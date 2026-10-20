-- Component-only transaction engine. All Native work goes through the explicit
-- canonical-receipt port; no UObject getters, actor setters or fallback wrappers.
local M={}
local function clone(t) local r={} for k,v in pairs(t) do r[k]={actor=v.actor,component=v.component} end return r end
local function state(v)
 assert(type(v)=='table' and type(v.visible)=='boolean' and type(v.hidden)=='boolean'
  and type(v.collision)=='number' and v.collision%1==0 and v.collision>=0 and v.collision<=5,'invalid original component state')
 return {visible=v.visible,hidden=v.hidden,collision=v.collision}
end
local function same(a,b) return a.visible==b.visible and a.hidden==b.hidden and a.collision==b.collision end
local hidden={visible=false,hidden=true,collision=0}
function M.new(P,T,C,ctx)
 assert(P.contract=='ShipParts.Native/v1' and type(ctx)=='table','canonical ship Native port required')
 assert(type(ctx.world)=='string' and type(ctx.layout)=='string','captured document required')
 local S={desired={},applied={},history={},revision=0,dirty=false,pending={},context=ctx}
 local busy,retired=false,false
 local unbind;local committed=clone(S.desired);local committedLayout=ctx.layout
 local function current(mode)
  if retired then return false end
  local ok,value=pcall(P.current,ctx,mode or 'edit')
  return ok and value==true
 end
 local function guard(mode) return function() return current(mode) end end
 local function native(mode,fn,...)
  assert(current(mode),'ship document/owner retired')
  local args=table.pack(...);args[args.n+1]=guard(mode)
  local result=table.pack(fn(table.unpack(args,1,args.n+1)))
  assert(current(mode),'ship document/owner retired during Native operation')
  return table.unpack(result,1,result.n)
 end
 local function entry(d,expected,mode)
  C.validate(T,ctx.world,ctx.layout,d.actor,d.component)
  local handle,f=native(mode,P.resolve,ctx,d.actor,d.component,expected)
  assert(handle~=nil and type(f)=='table' and f.actor==d.actor and f.component==d.component
   and f.actor_class==T.actor_class and f.component_class==T.component_class
   and f.mesh==T.parts[d.component].mesh and f.guid==T.parts[d.component].guid
   and f.authored_actor==true and f.owned==true and f.instanced==false and f.collision_local==true,
   'component identity/admission differs from cooked policy')
  assert(expected==nil or rawequal(handle,expected),'component replaced/aliased within this session')
  return {handle=handle,d={actor=d.actor,component=d.component},before=state(native(mode,P.read,handle))}
 end
 function S.pick()
  assert(not busy and #S.pending==0 and current(),'ship transaction unavailable')
  local hit=native('edit',P.pick,ctx)
  assert(type(hit)=='table' and hit.blocked==true and hit.component~=nil and hit.handle~=nil,'no actual canonical ship component hit')
  assert(hit.instance==nil or hit.instance==-1,'instanced selection refused')
  local key=C.validate(T,ctx.world,ctx.layout,hit.actor,hit.component)
  local e=entry({actor=hit.actor,component=hit.component},hit.handle,'edit')
  assert(rawequal(e.handle,hit.handle),'trace receipt does not resolve to exact component')
  return key,e.d
 end
 function S.list()
  assert(not busy and #S.pending==0,'ship transaction unavailable')
  local input=native('edit',P.inventory,ctx);assert(type(input)=='table' and #input<=512,'invalid ship inventory')
  local out,seen={},{}
  for _,d in ipairs(input) do
   local key=C.validate(T,ctx.world,ctx.layout,d.actor,d.component);assert(not seen[key],'ambiguous authored component path');seen[key]=true
   out[#out+1]={key=key,actor=d.actor,component=d.component,hidden=S.desired[key]~=nil,hull=T.parts[d.component].hull}
  end
  table.sort(out,function(a,b) return a.key<b.key end);return out
 end
 function S.change(set,options)
  options=options or {}
  local mode=options.cleanup and 'cleanup' or 'edit'
  assert(not options.cleanup or next(set)==nil,'cleanup may only restore the owned hidden set')
  assert(not busy and #S.pending==0 and current(mode),'ship transaction unavailable')
  set=clone(set);C.encode(T,ctx.world,ctx.layout,set) -- all validation before any Native write
  local previous=clone(S.desired);local keys,seen={},{}
  for k in pairs(set) do keys[#keys+1]=k;seen[k]=true end
  for k in pairs(S.applied) do if not seen[k] then keys[#keys+1]=k end end;table.sort(keys)
  local J={phase='preflight',index=1,field=1,plans={},touched={},error=nil,rollback_errors={}}
  busy=true;S.job=J
  local function finish(ok)
   if ok then
    local nextApplied={}
    for _,r in ipairs(J.plans) do if set[r.key] then nextApplied[r.key]={handle=r.handle,d=r.d,original=r.original} end end
    S.desired=set;S.applied=nextApplied
    if options.history~=false then S.history[#S.history+1]=previous;if #S.history>64 then table.remove(S.history,1) end end
    S.revision=S.revision+1;S.dirty=options.dirty~=false
   end
   busy=false;S.job=nil;J.phase='done';J.ok=ok;return true
  end
  local function failed(reason)
   J.error=tostring(reason);J.phase='rollback';J.index=#J.touched;J.field=1
   if J.index==0 then return finish(false) end
   return false
  end
  local setters={P.set_visible,P.set_hidden,P.set_collision}
  local fields={'visible','hidden','collision'}
  local function restoreStep()
   if not current('cleanup') then
    S.pending=J.touched;J.rollback_errors[#J.rollback_errors+1]='cleanup scope retired';return finish(false)
   end
   local r=J.touched[J.index]
   if not r then return finish(false) end
   local ok,err=pcall(function()
    -- Resolution is repeated before rollback, so no stale/recycled handle is read.
    if J.field==1 then
     local valid,observed=pcall(entry,r.d,r.handle,'cleanup')
     if not valid then J.field=4;error(observed,0) end -- skip ALL setters for an unresolvable receipt
     r.rollback_state=observed.before
    end
    if J.field<=3 then
     local field=fields[J.field]
     -- A schema refusal occurs before ProcessEvent. Unchanged fields need no
     -- undo; calling the refused setter again would invent cleanup ownership.
     if r.rollback_state[field]~=r.before[field] then
      assert(native('cleanup',setters[J.field],r.handle,r.before[field])==true,'component rollback setter refused: '..field)
     end
    else assert(same(state(native('cleanup',P.read,r.handle)),r.before),'component rollback readback differs') end
   end)
   if not ok then J.rollback_errors[#J.rollback_errors+1]=tostring(err);r.rollback_failed=true end
   J.field=J.field+1
   if J.field>4 then
    if r.rollback_failed then S.pending[#S.pending+1]=r end
    J.index=J.index-1;J.field=1
   end
   if J.index<1 then return finish(false) end
   return false
  end
  function J.step()
   if J.phase=='done' then return true end
   if J.phase=='rollback' then return restoreStep() end
   local ok,result=pcall(function()
    assert(current(mode),'ship scope retired')
    if J.phase=='preflight' then
     local key=keys[J.index]
     if not key then J.phase='apply';J.index=1;J.field=1;return false end
     local old=S.applied[key];local d=set[key] or old.d
     local r=entry(d,old and old.handle,mode);r.key=key
     r.original=old and old.original or r.before;r.after=set[key] and hidden or r.original
     J.plans[#J.plans+1]=r;J.index=J.index+1;return false
    end
    local r=J.plans[J.index]
    if not r then return finish(true) end
    if J.field==1 then
     local observed=entry(r.d,r.handle,mode)
     assert(same(observed.before,r.before),'component state drift since preflight')
     J.touched[#J.touched+1]=r -- retain journal before first mutation, even a throwing setter
    end
    if J.field<=3 then assert(native(mode,setters[J.field],r.handle,r.after[fields[J.field]])==true,'component setter refused')
    else assert(same(state(native(mode,P.read,r.handle)),r.after),'component readback differs') end
    J.field=J.field+1
    if J.field>4 then J.index=J.index+1;J.field=1 end
    return false
   end)
   if not ok then return failed(result) end
   return result
  end
  function J.cancel()
   if J.phase=='done' then return true end
   if J.phase~='rollback' then failed('package disabled') end
   while J.phase~='done' do restoreStep() end
   return #S.pending==0,table.concat(J.rollback_errors,' | ')
  end
  return J
 end
 function S.hide(key,d)
  assert(not S.desired[key],'component already hidden');local set=clone(S.desired);set[key]=d;return S.change(set)
 end
 function S.show(key)
  assert(S.desired[key],'component is not hidden');local set=clone(S.desired);set[key]=nil;return S.change(set)
 end
 function S.undo()
  local set=S.history[#S.history];assert(set,'nothing to undo')
  local J=S.change(set,{history=false});local step=J.step
  function J.step() local done=step();if done and J.ok and not J.undo_consumed then table.remove(S.history);J.undo_consumed=true end;return done end
  return J
 end
 function S.encode()
  assert(not busy and #S.pending==0 and current(),'ship save refused: transaction/cleanup pending')
  return C.encode(T,ctx.world,ctx.layout,S.desired)
 end
 function S.load(text) return S.change(C.decode(T,ctx.world,ctx.layout,text),{history=false,dirty=false}) end
 function S.save()
  local text=S.encode();local revision=S.revision
  busy=true -- a persistence callback cannot start another edit/save in this session
  local ok,receipt=pcall(native,'edit',P.persist,ctx,text,revision)
  busy=false
  assert(ok,receipt)
  assert(type(receipt)=='table' and receipt.world==ctx.world and receipt.layout==ctx.layout
   and receipt.revision==revision and receipt.bytes==text and S.revision==revision,'ship persistence not confirmed for exact document/bytes')
  committed=clone(S.desired);committedLayout=ctx.layout;S.dirty=false;return receipt
 end
 function S.cleanup()
  assert(not busy,'ship transaction running')
  -- Retry retained rollback journal first. No world-retired getters are allowed.
  local pending=S.pending;S.pending={}
  for _,r in ipairs(pending) do
   local ok,why=pcall(function()
    entry(r.d,r.handle,'cleanup')
    for i,f in ipairs({'visible','hidden','collision'}) do assert(native('cleanup',({P.set_visible,P.set_hidden,P.set_collision})[i],r.handle,r.before[f])==true) end
    assert(same(state(native('cleanup',P.read,r.handle)),r.before))
   end)
   if not ok then r.cleanup_error=tostring(why);S.pending[#S.pending+1]=r end
  end
  local errors={};for _,r in ipairs(S.pending)do errors[#errors+1]='ship component '..tostring(r.d.actor)..'/'..tostring(r.d.component)..': '..tostring(r.cleanup_error) end
  return #S.pending==0,table.concat(errors,' | ')
 end
 function S.restore_all()
  assert(current('cleanup'),'explicit current cleanup scope required to restore hides')
  return S.change({},{history=false,dirty=false,cleanup=true})
 end
 function S.busy() return busy end
 function S.abandon() if unbind then unbind();unbind=nil end;retired=true;busy=false;S.job=nil;S.desired={};S.applied={};S.pending={};S.history={} end
 if type(P.bind_session)=='function'then
  local hooks={}
  local function logical(mode)
   if retired then return false end
   if P.logical_current then return P.logical_current(ctx,mode)==true end
   return current(mode)
  end
  function hooks.capture(view)
   if busy or #S.pending>0 or not logical('edit')or view.name~=ctx.layout or view.world~='PirateIsland'then return nil end
   local h={revision=S.revision,layout=ctx.layout,bytes=C.encode(T,ctx.world,ctx.layout,S.desired)}
   return h,clone(S.desired),S.revision
  end
  function hooks.current(h)return type(h)=='table'and not busy and #S.pending==0 and logical('cleanup')end
  function hooks.unchanged(h)return hooks.current(h)and logical('edit')and S.revision==h.revision
   and C.encode(T,ctx.world,h.layout,S.desired)==h.bytes end
  function hooks.retarget(old,new)
   if old.name~=new.name or old.target_path~=new.target_path then S.dirty=true end
  end
  function hooks.finalize(h,set,revision,kind,view)
   if not hooks.current(h)then return false end
   if kind=='manual'then
    if not logical('edit')then P.rebind(ctx)end
    if ctx.layout~=view.name or not logical('edit')then return false end
    committed=clone(set);committedLayout=view.name
    S.dirty=S.revision~=revision or C.encode(T,ctx.world,ctx.layout,S.desired)~=C.encode(T,ctx.world,ctx.layout,committed)
   end
   return true -- recovery never retargets or clears main dirty state
  end
  function hooks.failed(h,kind)
   if kind=='manual'and logical('cleanup')and not logical('edit')then
    -- Rebind preserves the actual new working target but marks intent dirty.
    P.rebind(ctx);S.dirty=true
   end
   return true
  end
  unbind=P.bind_session(ctx,hooks)
 end
 return S
end
return M
