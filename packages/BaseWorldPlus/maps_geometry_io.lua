-- Game-thread companion IO. Exact operation kind/target; no filename inference.
-- Lua offers no exclusive-open/no-replace primitive. This preserves existing
-- temporary/backup bytes and detects changed destinations at its publication
-- boundary; concurrent filesystem no-clobber/atomic replacement is not claimed.
local M={}
local function literal(v) return type(v)=='string' and #v>0 and #v<=4096 and not v:find('[%c]') end
local function number(v) return type(v)=='number' and v%1==0 and v>=0 and v<=2147483647 end
local function rows(set)
 local a={} for k,v in pairs(set) do assert(v==true and literal(k),'invalid geometry actor');a[#a+1]=k end
 table.sort(a);assert(#a<=256,'too many hidden actors');return a
end
function M.encode(target,set,kind,source)
 assert(kind=='manual' or kind=='recovery','invalid geometry kind')
 assert(literal(target.world) and literal(target.name) and literal(target.target_path),'literal target required')
 assert(source.world==target.world and number(source.revision),'invalid captured geometry')
 assert(source.document_kind=='saved' or source.document_kind=='unsaved','invalid source document')
 assert(source.document_kind~='saved' or literal(source.source_name),'saved source name required')
 local keys=rows(set)
 local a={kind=='manual' and 'FAPP_GEOMETRY_MAIN_V2' or 'FAPP_GEOMETRY_RECOVERY_V1',target.world,target.name,
  target.target_path,source.document_kind,source.source_name or '',tostring(source.revision),tostring(#keys)}
 for _,k in ipairs(keys) do a[#a+1]=k end
 return table.concat(a,'\n')..'\n'
end
function M.decode(text,target,kind)
 assert(type(text)=='string' and #text<=1100000,'geometry companion too large')
 local a={} for line in text:gmatch('(.-)\n') do a[#a+1]=line end
 assert(a[1]==(kind=='manual' and 'FAPP_GEOMETRY_MAIN_V2' or 'FAPP_GEOMETRY_RECOVERY_V1'),'geometry kind mismatch')
 assert(a[2]==target.world and a[3]==target.name and a[4]==target.target_path,'exact document/target mismatch')
 local count,revision=tonumber(a[8]),tonumber(a[7])
 assert(number(count) and count<=256 and number(revision) and #a==count+8,'invalid geometry envelope')
 assert(a[5]=='saved' and literal(a[6]) or a[5]=='unsaved' and a[6]=='','invalid captured document')
 local set={};for i=9,#a do assert(literal(a[i]) and not set[a[i]],'invalid/duplicate geometry actor');set[a[i]]=true end
 return set,{world=a[2],name=a[3],target_path=a[4],document_kind=a[5],source_name=a[6]~='' and a[6] or nil,revision=revision}
end
function M.path(target,kind)
 assert(literal(target.target_path),'literal target path required')
 assert(kind=='manual' or kind=='recovery','invalid geometry kind')
 return target.target_path..(kind=='manual' and '.faphidden' or '.faphidden.recovery')
end
local dir=assert(debug.getinfo(1,'S').source:match('^@(.+[\\/])'))
M.writeBytes=dofile(dir..'../Core/companion_io.lua').writeBytes

function M.write(target,set,current,kind,source,operation)
 return M.writeBytes(M.path(target,kind),M.encode(target,set,kind,source),current,operation)
end
function M.writeCatalog(path,bytes,current,operation)
 assert(type(bytes)=='string' and #bytes<=1024 and bytes:match('^FAPP_CATALOG_V1\n[^\r\n]+\n$'),'invalid catalog metadata')
 return M.writeBytes(path..'.fapcatalog',bytes,current,operation,true)
end
return M
