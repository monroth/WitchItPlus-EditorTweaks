-- Literal, bounded companion data. Never loads Lua or serializes native references.
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
local IO=dofile(dir..'maps_geometry_io.lua')
local M={MAX=128}
local function literal(v) return type(v)=='string' and #v>0 and #v<=4096 and not v:find('[%c]') end
local function plain(v) return type(v)=='table' and getmetatable(v)==nil end
local function num(v,bound) return type(v)=='number' and v==v and math.abs(v)<=bound end
local function keys(v,allow)
 assert(plain(v),'plain teleporter data required')
 for k in pairs(v) do assert(allow[k],'unknown teleporter field') end
end
local function position(v)
 keys(v,{X=true,Y=true,Z=true,Yaw=true})
 for _,k in ipairs({'X','Y','Z'}) do assert(num(v[k],1e7),'invalid teleporter coordinate') end
 assert(num(v.Yaw,1e6),'invalid teleporter yaw')
end
local function copy(v,seen,depth)
 if type(v)~='table' then return v end
 assert(getmetatable(v)==nil,'plain teleporter data required')
 seen=seen or {};depth=depth or 0;assert(depth<=12 and not seen[v],'cyclic/deep teleporter data refused');seen[v]=true
 local r={} for k,x in pairs(v) do r[k]=copy(x,seen,depth+1) end;seen[v]=nil;return r
end
function M.copy(v)return copy(v,{},0)end
function M.validate(rows,catalog)
 assert(plain(rows),'plain teleporter document required')
 local count,textBytes=0,0
 for id,r in pairs(rows) do
  count=count+1;assert(count<=M.MAX and literal(id),'invalid teleporter identity/count')
  keys(r,{id=true,baked=true,removed=true,entry=true,exit=true,extent=true,effects=true,transferVelocity=true,velocity=true,link=true,decor=true})
  assert(r.id==id,'teleporter key mismatch')
  textBytes=textBytes+#id+(r.baked and type(r.baked)=='string' and #r.baked or 0)+(r.link and type(r.link)=='string' and #r.link or 0)
  if r.baked then assert(literal(r.baked) and id=='b:'..r.baked,'exact baked path required')
  else assert(id:match('^n:[%w_-]+$') and #id<=66,'invalid new teleporter id') end
  assert(type(r.removed)=='boolean' and type(r.effects)=='boolean' and type(r.transferVelocity)=='boolean','invalid teleporter flags')
  position(r.entry);position(r.exit);keys(r.extent,{X=true,Y=true,Z=true})
  for _,k in ipairs({'X','Y','Z'}) do assert(num(r.extent[k],1e5) and r.extent[k]>=1,'invalid trigger extent') end
  assert(num(r.velocity,10) and r.velocity>=0,'invalid velocity multiplier')
  assert(r.link==nil or literal(r.link) and r.link~=id,'invalid/self teleporter link')
  assert(plain(r.decor) and #r.decor<=8,'invalid decoration bindings')
  local decor={}
  for k,path in pairs(r.decor) do
   assert(type(k)=='number' and k%1==0 and k>=1 and k<=#r.decor and literal(path),'invalid decoration path')
   assert(not decor[path],'duplicate decoration on one trigger');decor[path]=true
   textBytes=textBytes+#path
  end
 end
 assert(textBytes*2+count*512+33000<=1100000,'teleporter document exceeds companion byte budget')
 for id,r in pairs(rows) do
  if r.baked and catalog then assert(catalog[id] and catalog[id].baked==r.baked,'baked teleporter not in this world') end
  if r.link then
   assert(rows[r.link] or (catalog and catalog[r.link]) or (not catalog and r.link:sub(1,2)=='b:'),'unresolved teleporter link')
  end
 end
 return true
end
function M.equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not M.equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end
 return true
end
local function hex(v) if v==nil then return '-' end;assert(literal(v));return (v:gsub('.',function(c)return string.format('%02x',c:byte())end)) end
local function unhex(v)
 if v=='-' then return nil end
 assert(#v>0 and #v<=8192 and #v%2==0 and not v:find('[^0-9a-f]'),'invalid companion string')
 local s=v:gsub('..',function(h)return string.char(tonumber(h,16))end);assert(literal(s));return s
end
local function integer(v) return num(v,2147483647) and v>=0 and v%1==0 end
local function envelope(target,kind)
 assert(kind=='manual' or kind=='recovery','invalid teleporter save kind')
 assert(literal(target.world) and literal(target.name) and literal(target.target_path),'exact native target required')
end
function M.path(target,kind) envelope(target,kind);return target.target_path..'.fapteleports'..(kind=='recovery' and '.recovery' or '') end
function M.encode(target,rows,kind,source)
 envelope(target,kind);M.validate(rows)
 assert(source.world==target.world and integer(source.revision),'invalid captured teleporter document')
 assert(source.document_kind=='saved' and literal(source.source_name) or source.document_kind=='unsaved' and source.source_name==nil,'invalid source binding')
 local ids={} for id in pairs(rows) do ids[#ids+1]=id end;table.sort(ids)
 local lines={'WITCHIT_TELEPORTERS_V1',kind,hex(target.world),hex(target.name),hex(target.target_path),source.document_kind,
  hex(source.source_name),tostring(source.revision),tostring(#ids)}
 for _,id in ipairs(ids) do
  local r=rows[id];local a={hex(id),hex(r.baked),r.removed and '1' or '0'}
  for _,p in ipairs({r.entry,r.exit}) do for _,k in ipairs({'X','Y','Z','Yaw'}) do a[#a+1]=string.format('%.17g',p[k]) end end
  for _,k in ipairs({'X','Y','Z'}) do a[#a+1]=string.format('%.17g',r.extent[k]) end
  a[#a+1]=r.effects and '1' or '0';a[#a+1]=r.transferVelocity and '1' or '0';a[#a+1]=string.format('%.17g',r.velocity)
  a[#a+1]=hex(r.link);a[#a+1]=tostring(#r.decor)
  for _,path in ipairs(r.decor) do a[#a+1]=hex(path) end
  lines[#lines+1]=table.concat(a,'|')
 end
 return table.concat(lines,'\n')..'\n'
end
function M.decode(bytes,target,kind)
 envelope(target,kind);assert(type(bytes)=='string' and #bytes<=1100000,'teleporter companion too large')
 local a={} for line in bytes:gmatch('(.-)\n') do a[#a+1]=line end
 assert(bytes:sub(-1)=='\n' and a[1]=='WITCHIT_TELEPORTERS_V1' and a[2]==kind,'teleporter format/kind mismatch')
 assert(unhex(a[3])==target.world and unhex(a[4])==target.name and unhex(a[5])==target.target_path,'exact world/document/path mismatch')
 local revision,count=tonumber(a[8]),tonumber(a[9])
 assert(integer(revision) and integer(count) and count<=M.MAX and #a==9+count,'invalid companion envelope')
 local source={world=target.world,source_name=unhex(a[7]),document_kind=a[6],revision=revision}
 assert(source.document_kind=='saved' and literal(source.source_name) or source.document_kind=='unsaved' and source.source_name==nil,'invalid captured binding')
 local rows={}
 local function flag(v) assert(v=='0' or v=='1','invalid companion bool');return v=='1' end
 for i=10,#a do
  local f={} for value in (a[i]..'|'):gmatch('(.-)|') do f[#f+1]=value end
  local id,baked=unhex(f[1]),unhex(f[2]);assert(not rows[id],'duplicate teleporter id')
  local n=tonumber(f[19]);assert(integer(n) and n<=8 and #f==19+n,'invalid row length')
  local r={id=id,baked=baked,removed=flag(f[3]),entry={},exit={},extent={},effects=flag(f[15]),transferVelocity=flag(f[16]),velocity=tonumber(f[17]),link=unhex(f[18]),decor={}}
  local index=4
  for _,p in ipairs({r.entry,r.exit}) do for _,k in ipairs({'X','Y','Z','Yaw'}) do p[k]=tonumber(f[index]);index=index+1 end end
  for _,k in ipairs({'X','Y','Z'}) do r.extent[k]=tonumber(f[index]);index=index+1 end
  for j=1,n do r.decor[j]=unhex(f[19+j]) end
  rows[id]=r
 end
 M.validate(rows);return rows,source
end
function M.write(target,rows,current,kind,source,operation)
 return IO.writeBytes(M.path(target,kind),M.encode(target,rows,kind,source),current,operation)
end
function M.read(target,current,kind)
 assert(current(),'teleporter read owner retired')
 local f,err,code=io.open(M.path(target,kind),'rb')
 if not current() then if f then pcall(f.close,f) end;error('teleporter read owner retired',0) end
 if not f then if code==2 then return {} end;error(err or 'teleporter companion unavailable',0) end
 local ok,bytes=pcall(f.read,f,1100001);local closed,done=pcall(f.close,f)
 assert(ok and closed and done==true,'teleporter companion read failed');assert(current(),'teleporter read owner retired')
 return M.decode(bytes,target,kind)
end
return M
