-- Isolated editor policy. Native Teleport/overlap behavior remains entirely cooked.
-- Engine/store injection is only for offline verification, not a runtime fallback.
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local Store=dofile(dir..'teleporter_store.lua')
local Native=dofile(dir..'teleporter_native.lua')
local M={}
function M.new(X,options)
 options=options or {}
 local factory=options.native or function(v,held)return Native.new(X,v,held)end
 local persist=options.persist or Store.write
 local read=options.reader or Store.read
 local claims=options.decor_claims or X.teleporter_decor_claims
 local T,s,closed={},nil,false
 local function owner(r)
  return not closed and s==r and X.api.is_live()==true and not X.Lifetime.transition
   and X.Lifetime.epoch==r.document.core_epoch and (not X.Lifetime.world or X.Lifetime.world==r.document.world_key:gsub('|',':',1))
 end
 local function current(r)
  if not r or not owner(r) then return false end
  return (options.document_current or Native.document_current)(X,r.document)==true
 end
 local function engine(r,edit)
  assert(current(r),'teleporter document retired')
  local document=r.document
  local function held()
   if not current(r) or r.document~=document then return false end
   for _,lease in pairs(r.claims) do if not claims or claims.current(lease)~=true then return false end end
   return current(r) and r.document==document
  end
  local n=factory(r.document,held);n.context(edit~=false);assert(held(),'teleporter document/decoration lease retired');return n
 end
 local function busy(r) assert(current(r) and not r.busy and not r.error,'teleporter editor busy/cleanup pending');r.busy=true end
 local function ids(set) local a={} for id in pairs(set) do a[#a+1]=id end;table.sort(a);return a end
 local function restoreJournal(r,journal)
  if not current(r) then return false end
  local done=true
  for i=#journal,1,-1 do
   local item=journal[i]
   if not item.done and item.touched then
    local ok=pcall(function()
     local n=engine(r)
     if item.created then assert(n.destroy(item.ref)==true,'new teleporter cleanup refused')
     elseif item.decor then n.restoreDecor(item.ref,item.before)
     else n.restore(item.ref,item.before) end
     assert(current(r),'rollback owner retired')
    end)
    if ok then item.done=true else done=false end
   end
  end
  return done
 end
 local function reconcile(r,rows)
  assert(not r.preserved,'authored teleporter companion preserved, not applied; reload layout in single-player before saving')
  busy(r)
  local journal,portalJournal,decorJournal,refs,base,expected,decorRefs,decorBase,decorExpected,newClaims={},{},{},{},{},{},{},{},{},{}
  for id,v in pairs(r.refs) do refs[id]=v end
  for id,v in pairs(r.baseline) do base[id]=v end
  for path,v in pairs(r.decorRefs) do decorRefs[path]=v end
  for path,v in pairs(r.decorBaseline) do decorBase[path]=v end
  local ok,err=pcall(function()
   for id,row in pairs(rows) do if row.baked and r.catalog[id] and Store.equal(row,r.catalog[id]) then rows[id]=nil end end
   Store.validate(rows,r.catalog)
   local decorWanted={}
   for _,row in pairs(rows) do for _,path in ipairs(row.decor) do
    if decorWanted[path]==nil then decorWanted[path]=row.removed else decorWanted[path]=decorWanted[path]and row.removed end
   end end -- shared decor hides only after every associated trigger is disabled
   for _,path in ipairs(ids(decorWanted)) do if not r.claims[path] then
    assert(claims and type(claims.acquire)=='function' and type(claims.current)=='function' and type(claims.release)=='function','shared decoration ownership coordinator required')
    local lease=claims.acquire(path,X.api.id,function()return current(r)end)
    assert(lease and claims.current(lease)==true and current(r),'decoration already owned or lease retired')
    r.claims[path]=lease;newClaims[path]=lease
   end end
   local n=engine(r)
   -- All existing participants are validated before the first mutation.
   for _,id in ipairs(ids(refs)) do
    local before=n.snapshot(refs[id]);assert(not r.expected[id] or n.sameSnapshot(before,r.expected[id]),'teleporter modified by another owner: '..id)
    local item={ref=refs[id],before=before};journal[#journal+1]=item;portalJournal[id]=item
   end
   for _,id in ipairs(ids(rows)) do if not refs[id] and rows[id].baked then
    local ref=assert(r.catalogRefs[id],'baked teleporter missing');local before=n.snapshot(ref)
    refs[id]=ref;base[id]=before;local item={ref=ref,before=before};journal[#journal+1]=item;portalJournal[id]=item
   end end
   for _,path in ipairs(ids(decorWanted)) do if not decorRefs[path] then
    local ref=n.decor(path);local before=n.snapshotDecor(ref)
    decorRefs[path]=ref;decorBase[path]=before
   end end
   for _,path in ipairs(ids(decorRefs)) do
    local before=n.snapshotDecor(decorRefs[path]);assert(not r.decorExpected[path] or n.sameSnapshot(before,r.decorExpected[path]),'decoration modified by another owner: '..path)
    local item={ref=decorRefs[path],before=before,decor=true};journal[#journal+1]=item;decorJournal[path]=item
   end
   local count=0 for _ in pairs(refs) do count=count+1 end
   for _,id in ipairs(ids(rows)) do if not refs[id] then
    count=count+1;assert(count<=256,'owned teleporter history limit reached; save/reload before adding more')
    local row=rows[id]
    local ref=n.spawn(row,function(partial)
     refs[id]=partial;local item={ref=partial,created=true,touched=true};journal[#journal+1]=item;portalJournal[id]=item -- retained before spawn completion
    end)
    refs[id]=ref;base[id]=assert(ref.baseline,'native spawn baseline missing')
   end end
   -- Quiesce the whole affected graph before configuring any destination.
   for _,id in ipairs(ids(refs)) do portalJournal[id].touched=true;n.quiesce(refs[id]) end
   for _,id in ipairs(ids(rows)) do
    local row=rows[id];local destination=row.link and (rows[row.link] or r.catalog[row.link]).exit or row.exit
    n.configure(refs[id],row,destination,base[id],row.link~=nil or not row.baked or not Store.equal(row.exit,r.catalog[id].exit))
   end
   for _,path in ipairs(ids(decorRefs)) do
    decorJournal[path].touched=true
    if decorWanted[path]==true then n.hideDecor(decorRefs[path],decorBase[path]) else n.restoreDecor(decorRefs[path],decorBase[path]) end
   end
   for _,id in ipairs(ids(refs)) do
    if rows[id] then n.activate(refs[id],rows[id],base[id])
    elseif refs[id].created then
     -- Undo of add keeps an owned, disabled tombstone until cleanup. Reversible
     -- editing never destroys an old actor before the transaction can commit.
     local row={removed=true};n.activate(refs[id],row,base[id])
    else n.restore(refs[id],base[id]) end
    expected[id]=n.snapshot(refs[id])
    if not rows[id] and not refs[id].created then refs[id]=nil;base[id]=nil;expected[id]=nil end -- restored baked actor ownership ends
   end
   for _,path in ipairs(ids(decorRefs)) do
    if decorWanted[path]~=nil then decorExpected[path]=n.snapshotDecor(decorRefs[path])
    else decorRefs[path]=nil;decorBase[path]=nil end -- release explicitly unbound decorations
   end
   assert(current(r),'teleporter transaction retired')
  end)
  if not ok then
   local restored=restoreJournal(r,journal)
   if not restored then r.busy=false;r.pending=journal;r.error='native rollback pending';return false,err end
   for path,lease in pairs(newClaims) do r.claims[path]=nil;claims.release(lease) end
   r.busy=false
   return false,err
  end
  r.refs=refs;r.baseline=base;r.expected=expected
  r.decorRefs=decorRefs;r.decorBaseline=decorBase;r.decorExpected=decorExpected
  r.rows=Store.copy(rows);r.revision=r.revision+1;r.dirty=r.unpublished==true or not Store.equal(r.rows,r.committed)
  for path,lease in pairs(r.claims) do if not decorRefs[path] then r.claims[path]=nil;claims.release(lease) end end
  r.busy=false
  return true
 end
 local function bind(v)
  assert((options.document_current or Native.document_current)(X,v),'current Creative layout changed')
  if s then
   local same=s.document.actor_key==v.actor_key and s.document.world_key==v.world_key
    and (s.document.name or '')==(v.name or '')
   if owner(s) and same then
    assert(not s.busy,'teleporter transaction active')
    s.document=Store.copy(v)
    return true
   end
   return false,'cleanup_required_before_document_replacement'
  end
  local r={direct=true,document=Store.copy(v),rows={},committed={},revision=0,dirty=false,busy=true,
   refs={},baseline={},expected={},decorRefs={},decorBaseline={},decorExpected={},undo={},claims={}}
  s=r
  local ok,why=pcall(function() local n=engine(r);r.catalog,r.catalogRefs=n.catalog();Store.validate({},r.catalog) end)
  if not ok then if s==r then s=nil end;return false,why end
  r.busy=false
  return true
 end
 function T.bind_current(v)return bind(v)end
 local function change(fn)
  local r=assert(s,'teleporter document unbound');assert(not r.loaded,'teleporter companion unapplied; use bteleport reload');assert(not r.busy and not r.error,'teleporter editor busy/cleanup pending')
  local rows=Store.copy(r.rows);fn(rows,r)
  local before=Store.copy(r.rows);local ok,why=reconcile(r,rows)
  if ok then r.undo[#r.undo+1]=before;if #r.undo>64 then table.remove(r.undo,1) end end
  return ok,why
 end
 local function row(rows,r,id)
  assert(type(id)=='string','literal teleporter id required')
  if not rows[id] then rows[id]=Store.copy(assert(r.catalog[id],'unknown teleporter: '..id)) end
  return rows[id]
 end
 function T.add(name,entry,exit,extent)
  assert(type(name)=='string','literal teleporter name required')
  return change(function(rows)
   local id='n:'..name;assert(not rows[id],'teleporter id exists')
   rows[id]={id=id,removed=false,entry=Store.copy(entry),exit=Store.copy(exit),extent=Store.copy(extent or {X=100,Y=100,Z=100}),
    effects=true,transferVelocity=true,velocity=1,decor={}}
  end)
 end
 function T.remove(id) return change(function(rows,r)row(rows,r,id).removed=true end) end
 function T.restore(id) return change(function(rows,r)row(rows,r,id).removed=false end) end
 function T.target(id,p) return change(function(rows,r)local v=row(rows,r,id);v.exit=Store.copy(p);v.link=nil end) end
 function T.link(id,destination) return change(function(rows,r)row(rows,r,id).link=destination end) end
 function T.pair(a,b) return change(function(rows,r)assert(a~=b,'distinct portals required');row(rows,r,a).link=b;row(rows,r,b).link=a end) end
 function T.move(id,p) return change(function(rows,r)local v=row(rows,r,id);assert(not v.baked,'baked entry movement not supported');v.entry=Store.copy(p) end) end
 function T.resize(id,e) return change(function(rows,r)row(rows,r,id).extent=Store.copy(e) end) end
 function T.options(id,effects,transfer,multiplier)
  return change(function(rows,r)local v=row(rows,r,id);v.effects=effects;v.transferVelocity=transfer;v.velocity=multiplier end)
 end
 function T.decorate(id,path) return change(function(rows,r)local v=row(rows,r,id);v.decor[#v.decor+1]=path end) end
 function T.undecorate(id) return change(function(rows,r)row(rows,r,id).decor={} end) end
 function T.undo()
  local r=assert(s,'teleporter document unbound');local before=r.undo[#r.undo];if not before then return false,'undo_empty' end
  local ok,why=reconcile(r,Store.copy(before));if ok then table.remove(r.undo) end;return ok,why
 end
 function T.list()
  local r=assert(s,'teleporter document unbound');assert(current(r),'teleporter document retired')
  local rows=Store.copy(r.catalog);for id,v in pairs(r.rows) do rows[id]=Store.copy(v) end;return rows
 end
 function T.status()
  if not s then return {current=false,records=0,requires_mod=false} end
  local count=0;for _ in pairs(s.loaded or s.rows)do count=count+1 end
  return {dirty=s.dirty,revision=s.revision,busy=s.busy==true,error=s.error or s.save_error,undo=#s.undo,current=current(s),records=count,requires_mod=count>0,preserved=s.preserved==true or s.loaded~=nil,applied=not s.preserved and s.loaded==nil}
 end
 -- A detached edit snapshot belongs only to this feature. Native file success
 -- decides publication; no companion can admit or veto the native writer.
 function T.file_snapshot()
  if not s then return end
  assert(not s.busy and not s.error and not s.loaded,'teleporters have unapplied edits; existing companion preserved')
  return {session=s,rows=Store.copy(s.rows),revision=s.revision,document=Store.copy(s.document),committed=Store.copy(s.committed),dirty=s.dirty,unpublished=s.unpublished,save_error=s.save_error}
 end
 -- Native Save As changes identity even if this feature cannot publish.
 function T.file_target(target,owner_key)
  if s and s.document.actor_key==owner_key then
   s.document.name=target.name;s.document.target_path=target.target_path;s.document.document_kind='saved'
  end
 end
 function T.file_saved(snapshot,target,serial,autosave)
  if not snapshot then return true end
  local r=snapshot.session
  if not autosave then T.file_target(target,snapshot.document.actor_key)end
  local d=snapshot.document
  local source={world=d.world,revision=snapshot.revision,document_kind=d.document_kind,
   source_name=d.document_kind=='saved'and d.name or nil}
  local called,ok,why=pcall(persist,target,snapshot.rows,function()return true end,'manual',source,serial)
  if not called or not ok then
   local message='teleporter companion '..target.target_path..'.fapteleports: '..tostring(called and why or ok)..'; native layout saved; dirty rows retained, save again to retry'
   if r and s==r then
    r.save_error=message
    if not autosave then r.unpublished=true;r.dirty=true end
   end
   error(message,0)
  end
  if r and s==r and not autosave then
   r.committed=Store.copy(snapshot.rows);r.unpublished=nil;r.dirty=not Store.equal(r.rows,r.committed);r.save_error=nil
  end
  return true
 end
 function T.file_restore(snapshot)
  local yes,why=T.bind_current(snapshot.document);assert(yes,why)
  yes,why=reconcile(s,Store.copy(snapshot.rows));assert(yes,why)
  s.committed=Store.copy(snapshot.committed);s.dirty=snapshot.dirty;s.unpublished=snapshot.unpublished;s.save_error=snapshot.save_error
  return true
 end
 function T.file_apply(v,rows,recovery,unpublished)
  local yes,why=T.cleanup();assert(yes,why)
  yes,why=T.bind_current(v);assert(yes,why)
  local r=s
  yes,why=reconcile(r,Store.copy(rows))
  if not yes then r.loaded=Store.copy(rows);error(why,0)end
  r.committed=Store.copy(rows);r.unpublished=unpublished==true;r.dirty=recovery==true or r.unpublished;r.undo={}
  return true
 end
 function T.file_load(v,target,recovery)
  return T.file_apply(v,read(target,function()return true end,'manual'),recovery)
 end
 function T.cleanup()
  local r=s;if not r then return true end
  if r.busy then return false,'teleporters: transaction active' end
  -- Teardown happens after package callbacks are revoked. Existing owned object
  -- references remain usable for rollback; no edit-context recapture is needed.
  local n=factory(r.document,function()return true end)
  local errors={}
  local function clean(name,fn)
   local ok,why=pcall(fn)
   if not ok then errors[#errors+1]=name..': '..tostring(why) end
   return ok
  end
  if r.pending then
   for i=#r.pending,1,-1 do local item=r.pending[i]
    if item.touched and not item.done then
     item.done=clean('teleporter rollback '..tostring(item.ref.name or item.ref.path or i),function()
      if item.created then assert(n.destroy(item.ref)==true,'destroy refused')
      elseif item.decor then n.restoreDecor(item.ref,item.before) else n.restore(item.ref,item.before) end
     end)
    end
   end
   if #errors==0 then r.pending=nil end
  end
  for _,path in ipairs(ids(r.decorRefs)) do
   if clean('teleporter decoration '..path,function()
    assert(n.sameSnapshot(n.snapshotDecor(r.decorRefs[path]),r.decorExpected[path]),'decoration modified by another owner')
    n.restoreDecor(r.decorRefs[path],r.decorBaseline[path])end)then r.decorRefs[path]=nil end
  end
  for _,id in ipairs(ids(r.refs)) do local ref=r.refs[id]
   if clean('teleporter '..id..' ('..tostring(ref.name or ref.path)..')',function()
    if n.retired and n.retired(ref)then return end
    if ref.created then assert(n.destroy(ref)==true,'destroy refused')
    else
     assert(n.sameSnapshot(n.snapshot(ref),r.expected[id]),'teleporter modified by another owner')
     n.restore(ref,r.baseline[id])
    end
   end)then r.refs[id]=nil end
  end
  if #errors>0 then return false,table.concat(errors,'; ') end
  local old=r.claims;s=nil;for _,lease in pairs(old)do claims.release(lease)end
  return true
 end
 function T.abandon()
  -- Call only from world/epoch abandonment or terminal package retirement.
  local old=s;s=nil;
  if old and claims then for _,lease in pairs(old.claims) do claims.release(lease) end end;return true
 end
 function T.retire() closed=true;return T.abandon() end
 return T
end
return M
