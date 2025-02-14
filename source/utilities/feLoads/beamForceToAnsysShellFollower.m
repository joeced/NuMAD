function beamForceToAnsysShellFollower(maptype,nodeData,loads,outfile)
%AD2ANSYS  Maps AeroDyn forces to an ANSYS blade FE model
% **********************************************************************
% *                   Part of the SNL NuMAD Toolbox                    *
% * Developed by Sandia National Laboratories Wind Energy Technologies *
% *             See license.txt for disclaimer information             *
% **********************************************************************
%   ad2ansys(maptype,nodeData,forcesfile,outfile)
%
%   Note: you may omit any or all of the filename arguments and the script
%         will provide a file selection box.
%
%     maptype = 'map2D_fxM0' Maintains Fx, Fy, and Mz
%                            fx forces produce zero Mz moment
%               'map3D_fxM0' (default) Maintains Fx, Fy, Mz, and root moments
%                            fx forces produce zero Mz moment
%
%     nodeData  = node numbers and coordinates for each node
%
%     forcesfile = name of file containing the load definition with
%     columns:
%       Z  - spanwise location of forces (center of aero element)
%       Fx - forces aligned with the X axis of the ANSYS blade model
%       Fy - forces aligned with the Y axis of the ANSYS blade model
%       M  - moments about Z axis
%       Alpha - CURRENTLY UNUSED
%       x_off -
%       y_off -
%
%     outfile = name of the output file to be /INPUT in ANSYS

%>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
% Transform loads from the FAST blade coordinate system the 
% ANYS Blade Coordinate System

beta=[0 -1 0; %Direction cosine matrix for a 90 degree clockwise rotation
      1 0 0;  %about the z axis. 
      0 0 1]; 
for i=1:length(loads.rBlade)
    F=beta*[loads.Fxb(i); loads.Fyb(i); loads.Fzb(i)];
    M=beta*[loads.Mxb(i); loads.Myb(i); loads.Mzb(i)];


    %Overwrite loads in the FAST CSYS with the ANSYS CSYS
    loads.Fxb(i)=F(1);
    loads.Fyb(i)=F(2);
    loads.Fzb(i)=F(3);

    loads.Mxb(i)=M(1);
    loads.Myb(i)=M(2);
    loads.Mzb(i)=M(3);
end
%<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
% set the default mapping algorithm
if ~exist('maptype','var') || isempty(maptype)
    maptype = 'map3D_fxM0';
end



%Look through nodeData, remove root nodes
z = 0;
for l = 1:length(nodeData(:,4))
    if nodeData(l,4) == 0
        continue
%         nodeData_new(l,:) = [];
    else
        z = z+1;
        nodeData_new(z,:)= nodeData(l,:);
    end
end
nodeData = nodeData_new;


switch maptype
    case 'map2D_fxM0'
        forcemap = map2D_fxM0(nodeData,loads);
    case 'map3D_fxM0'
        forcemap = map3D_fxM0(nodeData,loads);
end


forcesums = check_sums(nodeData,loads,forcemap);

% open file selector if 'outfile' not given
if ~exist('outfile','var') || isempty(outfile)
    outfile = fullfile(nlistpath,'forces.src');
    [fn,pn] = uiputfile( ...
        {'*.*', 'All files (*.*)'},...
        'Save Output As',outfile);
    if isequal(fn,0)
        % the user canceled file selection
        return
    end
    outfile = fullfile(pn,fn);
end

% write the ansys commands which apply the calculated forces
writeforcefile(outfile,forcemap,forcesums,maptype);

% plot the results
if (1)
    figure(1007);
    subplot(2,2,[1,3])
    ds = ceil(size(nodeData,1)/1e3); % downsample to 1000 points
    k = 1:ds:size(nodeData,1);
    quiver3(nodeData(k,2),nodeData(k,3),nodeData(k,4),...
        forcemap.fx(k), forcemap.fy(k), zeros(size(forcemap.fx(k))));
    title('Force vectors visual check (downsampled)');
    axis equal;
    subplot(2,2,2)
    [~,k] = sort(nodeData(:,4));  % sort order, sorting on Z
    plot(nodeData(k,4),forcemap.fx(k),'.');
    xlabel('z'); ylabel('fx')
    subplot(2,2,4)
    plot(nodeData(k,4),forcemap.fy(k),'.');
    xlabel('z'); ylabel('fy')
end
end


function forces = read_forces(filename)

% Open the file
fid = fopen(filename);
if (fid == -1)
    error('Could not open file "%s"',filename);
end
header = fgetl(fid);  %#ok (header not used)
filecontents = fread(fid,inf,'uint8=>char')';
fclose(fid);

% 'Z (m)	Fx (N)	Fy (N)	M (N-m)	Alpha	x_off	y_off'
forces = textscan(filecontents,repmat('%f',1,7));
end

function forcemap = map2D_fxM0(nodeData,loads)
% Map forces such that the equivalent Fx Fy and M are maintained for each
% section.  It is assumed that only the fy forces contribute to M and fx
% are balanced to produce no moment.
mesh.n = nodeData(:,1);
mesh.x = nodeData(:,2);
mesh.y = nodeData(:,3);
mesh.z = nodeData(:,4);

% divide nodes into spanwise groups
bin = zeros(size(mesh.n));  % each FEA node will be assigned to a bin
for nk = 1:length(mesh.n)
    halfDZ = loads.rBlade(1);  % initialize section width
    for bk = 1:numel(loads.rBlade);
        OBedge = loads.rBlade(bk) + halfDZ;  % outboard edge of section
        if (mesh.z(nk) <= OBedge) || (bk==numel(loads.rBlade));
            bin(nk) = bk;
            break
        end
        halfDZ = loads.rBlade(bk+1) - OBedge;
    end
end

forcemap.n = nodeData(:,1);
forcemap.bin = bin;
forcemap.fx = zeros(size(mesh.n));
forcemap.fy = zeros(size(mesh.n));
for bk = 1:length(loads.Fxb)
    i = find(bin==bk);
    N = length(i);
    x = mesh.x(i)-loads.presweep(bk);
    y = mesh.y(i)-loads.prebend(bk);
    mx = mean(x);
    my = mean(y);
    mxx = mean(x.^2);
    myy = mean(y.^2);
    %mxy = mean(x.*y);
    A = [my,   1,  0,   0;
        0,    0,  mx,  1;
        0     0,  mxx, mx;
        -myy, -my, 0,   0];
    F = 1/N * [loads.Fxb(bk); loads.Fyb(bk); loads.Mzb(bk); 0];
    ab = A\F;
    forcemap.fx(i) = ab(1)*y + ab(2);
    forcemap.fy(i) = ab(3)*x + ab(4);
end
end


function forcemap = map3D_fxM0(nodeData,loads)
% Map forces such that the equivalent Fx Fy and M are maintained for each
% section.  It is assumed that only the fy forces contribute to M and fx
% are balanced to produce no moment.
mesh.n = nodeData(:,1);
mesh.x = nodeData(:,2);
mesh.y = nodeData(:,3);
mesh.z = nodeData(:,4);

% aero.Z = forces{1};
% aero.Fx = forces{2};
% aero.Fy = forces{3};
% aero.M = forces{4};
% aero.alpha = forces{5};
% aero.xoff = forces{6};
% aero.yoff = forces{7};

% divide nodes into spanwise groups
bin = zeros(size(mesh.n));  % each FEA node will be assigned to a bin
for nk = 1:length(mesh.n)
    halfDZ = loads.rBlade(1);  % initialize section width
    for bk = 1:numel(loads.rBlade);
        OBedge = loads.rBlade(bk) + halfDZ;  % outboard edge of section
        if (mesh.z(nk) <= OBedge) || (bk==numel(loads.rBlade));
            bin(nk) = bk;
            break
        end
        halfDZ = loads.rBlade(bk+1) - OBedge;
    end
end

forcemap.n = nodeData(:,1);
forcemap.bin = bin;
forcemap.fx = zeros(size(mesh.n));
forcemap.fy = zeros(size(mesh.n));
%% EMA added:
forcemap.fz = zeros(size(mesh.n));
%% END
for bk = 1:length(loads.Fxb)
    i = find(bin==bk);
    N = length(i);
    x = mesh.x(i)-loads.presweep(bk);
    y = mesh.y(i)-loads.prebend(bk);
    z = mesh.z(i);
    mx = mean(x);
    my = mean(y);
    mz = mean(z);
    mxx = mean(x.^2);
    myy = mean(y.^2);
    mzz = mean(z.^2);
    %mxy = mean(x.*y);
    mzx = mean(z.*x);
    mzy = mean(z.*y);
    %% Original
%     A = [mz,   my,   1,   0,   0,   0;
%         0,    0,    0,   mz,  mx,  1;
%         0,    0,    0,   mzx, mxx, mx;
%         -mzy, -myy, -my,  0,   0,   0;
%         0,    0,    0,   mzz, mzx, mz;
%         mzz,  mzy,  mz,  0,   0,   0];
%     F = 1/N * [aero.Fx(bk); aero.Fy(bk); aero.M(bk); 0; ...
%         aero.Z(bk)*aero.Fy(bk); aero.Z(bk)*aero.Fx(bk)];
%     abc = A\F;
	%% Changed to:
    %% Add/modify equations to include forces in the Z-direction.
    A = [mz,   my,   1,   0,   0,   0,   0;
       0,    0,    0,   mz,  mx,  1,   0;
       0,    0,    0,    0,   0,  0,   1;
       0,    0,    0,   mzx, mxx, mx,  0;
       -mzy, -myy, -my,  0,   0,   0,  0;
       0,    0,    0,   mzz, mzx, mz, -my;
       mzz,  mzy,  mz,  0,   0,   0,  -mx];
    F = 1/N * [loads.Fxb(bk); loads.Fyb(bk); loads.Fzb(bk); loads.Mzb(bk); 0; ...
       loads.rBlade(bk)*loads.Fyb(bk); loads.rBlade(bk)*loads.Fxb(bk)];
    abc = A\F;
	%% END
    forcemap.fx(i) = abc(1)*z + abc(2)*y + abc(3);
    forcemap.fy(i) = abc(4)*z + abc(5)*x + abc(6);
    %% EMA added:
    forcemap.fz(i) = abc(7);
    %% END
end
end


function forcesums = check_sums(nodeData,loads,forcemap)

forcesums.Z = loads.rBlade;
forcesums.Fx(:,1) = loads.Fxb;
forcesums.Fy(:,1) = loads.Fyb;
forcesums.M(:,1) = loads.Mzb;
%% EMA original:
% forcesums.RootMx(:,1) = loads.rBlade .* loads.Fyb;
% forcesums.RootMy(:,1) = loads.rBlade .* loads.Fxb;
%% changed to:
forcesums.RootMx(:,1) = -loads.rBlade .* loads.Fyb + loads.prebend.*loads.Fzb;
forcesums.RootMy(:,1) = loads.rBlade .* loads.Fxb - loads.presweep.*loads.Fzb;
%% END

for bk = 1:length(loads.Fxb)
    i = find(forcemap.bin==bk);
    x = nodeData(i,2)-loads.presweep(bk);
    y = nodeData(i,3)-loads.prebend(bk);
    z = nodeData(i,4);
    forcesums.Fx(bk,2) = sum(forcemap.fx(i));
    forcesums.Fy(bk,2) = sum(forcemap.fy(i));
    forcesums.M(bk,2) = sum(-y.*forcemap.fx(i) + x.*forcemap.fy(i));
    %% EMA original:
%     forcesums.RootMx(bk,2) = sum(z.*forcemap.fy(i));
%     forcesums.RootMy(bk,2) = sum(z.*forcemap.fx(i));
    %% changed to:
    x = nodeData(i,2);
    y = nodeData(i,3);
    forcesums.RootMx(bk,2) = sum(-z.*forcemap.fy(i) + y.*forcemap.fz(i));
    forcesums.RootMy(bk,2) = sum(z.*forcemap.fx(i) - x.*forcemap.fz(i));
    %% END
end

end


function writeforcefile(filename,forcemap,forcesums,maptype)
fid = fopen(filename,'wt');
if (fid == -1)
    error('Could not open file "%s"',filename);
end

if exist('forcesums','var')
    fprintf(fid,'!========== FORCE MAPPING SUMMARY ==========');
    fprintf(fid,'\n!maptype = "%s"',maptype);
    
    s = sprintf('\n!                Z =%s      TOTAL     ',sprintf('  %14.6e',forcesums.Z));
    fprintf(fid,'%s',s);
    fprintf(fid,'\n!%s',repmat('-',1,length(s)));
    
    fprintf(fid,'\n!Input          Fx =');
    fprintf(fid,'  %14.6e',forcesums.Fx(:,1));
    fprintf(fid,'  %14.6e',sum(forcesums.Fx(:,1)));
    fprintf(fid,'\n!Output    sum(fx) =');
    fprintf(fid,'  %14.6e',forcesums.Fx(:,2));
    fprintf(fid,'  %14.6e',sum(forcesums.Fx(:,2)));
    
    fprintf(fid,'\n!%s',repmat('-',1,length(s)));
    
    fprintf(fid,'\n!Input          Fy =');
    fprintf(fid,'  %14.6e',forcesums.Fy(:,1));
    fprintf(fid,'  %14.6e',sum(forcesums.Fy(:,1)));
    fprintf(fid,'\n!Output    sum(fy) =');
    fprintf(fid,'  %14.6e',forcesums.Fy(:,2));
    fprintf(fid,'  %14.6e',sum(forcesums.Fy(:,2)));
    
    fprintf(fid,'\n!%s',repmat('-',1,length(s)));
    
    fprintf(fid,'\n!Input           M =');
    fprintf(fid,'  %14.6e',forcesums.M(:,1));
    fprintf(fid,'  %14.6e',sum(forcesums.M(:,1)));
    fprintf(fid,'\n!sum(-y*fx + x*fy) =');
    fprintf(fid,'  %14.6e',forcesums.M(:,2));
    fprintf(fid,'  %14.6e',sum(forcesums.M(:,2)));
    
    fprintf(fid,'\n!%s',repmat('-',1,length(s)));
    
    fprintf(fid,'\n!Input        Z*Fy =');
    fprintf(fid,'  %14.6e',forcesums.RootMx(:,1));
    fprintf(fid,'  %14.6e',sum(forcesums.RootMx(:,1)));
    fprintf(fid,'\n!Output  sum(z*fy) =');
    fprintf(fid,'  %14.6e',forcesums.RootMx(:,2));
    fprintf(fid,'  %14.6e',sum(forcesums.RootMx(:,2)));
    
    fprintf(fid,'\n!%s',repmat('-',1,length(s)));
    
    fprintf(fid,'\n!Input        Z*Fx =');
    fprintf(fid,'  %14.6e',forcesums.RootMy(:,1));
    fprintf(fid,'  %14.6e',sum(forcesums.RootMy(:,1)));
    fprintf(fid,'\n!Output  sum(z*fx) =');
    fprintf(fid,'  %14.6e',forcesums.RootMy(:,2));
    fprintf(fid,'  %14.6e',sum(forcesums.RootMy(:,2)));
    
    fprintf(fid,'\n\n');
end


fprintf(fid,'finish\n/prep7\n\n');

fprintf(fid,'csys,0\n');
fprintf(fid,'allsel\n');
fprintf(fid,'et,33,FOLLW201\n');
fprintf(fid,'KEYOPT,33,2,0\n');
fprintf(fid,'TYPE, 33\n\n'); %Activates an element type number to be assigned to subsequently defined elements. 

for nk = 1:length(forcemap.n)
    F=[forcemap.fx(nk) forcemap.fy(nk) forcemap.fz(nk)];
    vlen=norm(F,2);
    FX=forcemap.fx(nk)/vlen;
    FY=forcemap.fy(nk)/vlen;
    FZ=forcemap.fz(nk)/vlen;
    
    fprintf(fid,'R,%d,%g,%g,%g,0,0,0 \n',forcemap.n(nk),FX,FY,FZ);
    fprintf(fid,'REAL, %d\n',forcemap.n(nk)); %Identifies the real constant set number to be assigned to subsequently defined elements.
    fprintf(fid,'E,%d \n',forcemap.n(nk)); %Define a new element with one node
    
    %Select follower element without knowing its element number
    fprintf(fid,'NSEL, S,NODE,,%d\n',forcemap.n(nk)); 
    fprintf(fid,'ESLN, S, 1\n'); 
    
    
    %Apply Load
    if vlen  % if not zero
        fprintf(fid,'sfe,all,1,pres,,%g\n',vlen);
    end   
    fprintf(fid,'allsel\n\n');
%     if forcemap.fx(nk)  % if not zero
%         fprintf(fid,'f,%d,fx,%g\n',forcemap.n(nk),forcemap.fx(nk));
%     end
%     if forcemap.fy(nk)  % if not zero
%         fprintf(fid,'f,%d,fy,%g\n',forcemap.n(nk),forcemap.fy(nk));
%     end
end

fclose(fid);
end
