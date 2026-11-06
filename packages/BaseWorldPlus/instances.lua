local dir=debug.getinfo(1,'S').source:match('^@(.+[\\/])')
local meshes=dofile(dir..'instance_meshes.lua')
local M={}
local fields={Translation={'X','Y','Z'},Rotation={'X','Y','Z','W'},Scale3D={'X','Y','Z'}}
function M.transform(c,index,world)
    local out={};c:GetInstanceTransform(index,out,world)
    local t={}
    for name,axes in pairs(fields)do t[name]={};for _,axis in ipairs(axes)do t[name][axis]=out[name][axis]end end
    return t
end
function M.set(c,row,hide)
    local t=row.transform
    local value={Translation=t.Translation,Rotation=t.Rotation,Scale3D=hide and {X=0,Y=0,Z=0}or t.Scale3D}
    c:UpdateInstanceTransform(row.index,value,false,true,true)
end
function M.row(c,index,path)
    return {kind='instance',path=path,mesh=c.StaticMesh:GetFullName():match('^%S+ (.+)$'),index=index,
        transform=M.transform(c,index,false)}
end
local function matrix(t)
    local q=t.Rotation;local x,y,z,w=q.X,q.Y,q.Z,q.W
    return {{1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)},
    {2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)},
    {2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)}}
end
local axes={'X','Y','Z'}
local function localRay(t,o,d)
    local mat=matrix(t);local p,r={},{}
    for i,k in ipairs(axes)do
        local scale=t.Scale3D[k];if math.abs(scale)<1e-10 then return end
        p[i]=0;r[i]=0
        for j,a in ipairs(axes)do p[i]=p[i]+mat[j][i]*(o[a]-t.Translation[a])/scale;r[i]=r[i]+mat[j][i]*d[a]/scale end
    end
    return p,r
end
local function sub(a,b)return {a[1]-b[1],a[2]-b[2],a[3]-b[3]}end
local function cross(a,b)return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
function M.ray(r,o,d,limit)
    local geometry=meshes[r.mesh];if not geometry then return end
    local p,ray=localRay(r.worldTransform,o,d);if not p then return end
    local best
    for i=1,#geometry.indices,3 do
        local a=geometry.vertices[geometry.indices[i]+1]
        local b=geometry.vertices[geometry.indices[i+1]+1]
        local c=geometry.vertices[geometry.indices[i+2]+1]
        local e1,e2=sub(b,a),sub(c,a)
        local h=cross(ray,e2)
        local det=dot(e1,h)
        if math.abs(det)>1e-12 then
            local s=sub(p,a);local u=dot(s,h)/det
            if u>=0 and u<=1 then local q=cross(s,e1);local v=dot(ray,q)/det
                if v>=0 and u+v<=1 then local distance=dot(e2,q)/det
                    if distance>=0 and distance<=limit and(not best or distance<best)then best=distance end
                end
            end
        end
    end
    return best
end
function M.supported(mesh)return meshes[mesh]~=nil end
return M
