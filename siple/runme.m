%% general script settings
plot_data_sets = false;
plot_meshes = true;
plot_grounding_line = true;
plot_friction_coefficient = true;
stress_balance = 'SSA';  % SSA or HO

%% add to path
addpath('../bin/');    % my scripts
addpath('../../bin');  % issm/trunk/bin
addpath('../../lib');  % issm/trunk/lib

% create output folders
if ~exist('models', 'file')
    mkdir models
end

if ~exist('figures', 'file')
    mkdir figures
end

%% Read input data

% read Bedmap2 data if not loaded
if ~exist('bm2', 'var')
    bm2 = read_bedmap2();
end

% read Rignot velocity if not loaded
if ~exist('rignot', 'var')
    rignot = read_rignot_velocity();
end

% visualize input data
if plot_data_sets
    close all
    plot_bed(bm2)
    plot_surface(bm2)
    plot_grounded(bm2)
    plot_velocity(rignot, 1)
end


%% Define model limits
% 1. Press 'add a contour (closed)'
% 2. Click around area of interest (no need to close polygon)
% 3. Press <Enter>
% 4. Close exptool dialog box by pressing 'Quit' button
% 5. Close figure
domain = 'DomainOutline.exp';
if ~exist(domain, 'file')
    if ~plot_data_sets
        plot_velocity(rignot, 1)
    end
    exptool(domain)
end


%% Mesh generation

% mesh parameters
if 0  % coarse mesh
    hinit = 10000;   % element size for the initial mesh
    hmax = 40000;    % maximum element size of the final mesh
    hmin = 5000;     % minimum element size of the final mesh
else  % fine mesh
    hinit = 5000;   % element size for the initial mesh
    hmax = 20000;    % maximum element size of the final mesh
    hmin = 2500;     % minimum element size of the final mesh
end
gradation = 1.7; % maximum size ratio between two neighboring elements
err = 8;         % maximum error between interpolated and control field

% generate an initial uniform mesh (resolution = hinit meters)
md = bamg(model, 'domain', domain, 'hmax', hinit);
%plotmodel(md,'data','mesh')
clear domain

% TODO: check if the velocity data below is oriented correctly
% interpolate velocities onto coarse mesh
vx_obs = InterpFromGridToMesh( ...
    rignot.x, rignot.y, ...
    rignot.vx, ...
    md.mesh.x, md.mesh.y, ...
    0);

vy_obs = InterpFromGridToMesh( ...
    rignot.x, rignot.y, ...
    rignot.vy, ...
    md.mesh.x, md.mesh.y, ...
    0);

vel_obs = sqrt(vx_obs.^2 + vy_obs.^2);

% adapt the mesh to minimize errorrunme in velocity interpolation
md = bamg(md, 'hmax', hmax, 'hmin', hmin, ...
    'gradation', gradation, 'field', vel_obs, 'err', err);

clear vx_obs vy_obs vel_obs;

if plot_meshes
    %figure
    plotmodel(md, 'data', 'mesh')
    saveas(gcf, 'figures/model_mesh')
    saveas(gcf, 'figures/model_mesh.pdf')
end

clear hinit hmax hmin gradation err;

% save model
save models/model_mesh_generation md;


%% Apply masks for grounded/floating ice

md = loadmodel('models/model_mesh_generation');

% interpolate onto our mesh vertices
groundedice = double(InterpFromGridToMesh(...
    bm2.x', bm2.y', bm2.grounded, ...
    md.mesh.x, md.mesh.y, 0));

% fill in the md.mask structure
% ice is grounded for mask equal one
md.mask.groundedice_levelset = groundedice;
clear groundedice

% interpolate onto our mesh vertices
ice = double(InterpFromGridToMesh(...
    bm2.x', bm2.y', bm2.grounded, ...
    md.mesh.x, md.mesh.y, 0));
ice(ice > 1.0e-5) = -1;   % make ice shelves count as ice

% ice is present when negative
%md.mask.ice_levelset = -1 * ones(md.mesh.numberofvertices, 1);% all is ice
md.mask.ice_levelset = ice;
clear ice

if plot_grounding_line
    plotmodel(md, ...
        'data', md.mask.groundedice_levelset, ...
        'title', 'grounded/floating', ...
        'data', md.mask.ice_levelset, ...
        'title', 'ice/no-ice');
    saveas(gcf, 'figures/model_grounding_line')
    saveas(gcf, 'figures/model_grounding_line.pdf')
end

% Save model
save models/model_set_mask md;


%% Parameterization
md = loadmodel('models/model_set_mask');
md = parameterize(md, 'model_params.m');

% define stress balance

if strcmp(stress_balance, 'SSA')
    md = setflowequation(md, 'SSA', 'all');
    
    % use SIA for slow ice
    %md = setflowequation(md, 'SSA', md.inversion.vel_obs > 100, ...
    %  'fill', 'SIA');
    
elseif strcmp(stress_balance, 'HO')
    n_layers = 3;
    md = extrude(md, n_layers, 0.9);
    md = setflowequation(md, 'HO', 'all');
    clear n_layers;
end


    
% Save model
save models/model_parameterization md;


%% Find stress balance (control method)

md = loadmodel('models/model_parameterization');

% Control general
md.inversion.iscontrol = 1;
md.inversion.maxsteps = 20;
md.inversion.maxiter = 40;
md.inversion.dxmin = 0.1;
md.inversion.gttol = 1.0e-4;
md.verbose=verbose('solution', true, 'control', true);

% Cost functions
md.inversion.cost_functions = [101 103 501];
md.inversion.cost_functions_coefficients = ...
    ones(md.mesh.numberofvertices, 3);
md.inversion.cost_functions_coefficients(:,1) = 1;
md.inversion.cost_functions_coefficients(:,2) = 1;
md.inversion.cost_functions_coefficients(:,3) = 8e-15;

% Controls
md.inversion.control_parameters = {'FrictionCoefficient'};
%md.inversion.min_parameters = 1 * ones(md.mesh.numberofvertices, 1);

% Min/max allowed values of FrictionCoefficient
md.inversion.min_parameters = 0 * ones(md.mesh.numberofvertices, 1);
md.inversion.max_parameters = 200 * ones(md.mesh.numberofvertices, 1);

% Additional parameters
md.stressbalance.restol = 0.01;
md.stressbalance.reltol = 0.1;
md.stressbalance.abstol = NaN;

% Solve
md.toolkits = toolkits;
md.cluster = generic('name', oshostname, 'np', 2);
md = solve(md, StressbalanceSolutionEnum);

% Update model friction fields accordingly
md.friction.coefficient = ...
    md.results.StressbalanceSolution.FrictionCoefficient;

if plot_friction_coefficient
    plotmodel(md, 'data', md.friction.coefficient, ...
        'FontSize#all', 12, ...
        'colormap#all', 'parula')
    saveas(gcf, 'figures/model_friction')
    saveas(gcf, 'figures/model_friction.pdf')
end

% Save model
save models/model_control_drag md;


%% Calculate stress balance and basal drag
% Find sliding exponents
s = averaging(md, 1 ./ md.friction.p, 0);
r = averaging(md, md.friction.q ./ md.friction.p, 0);

% Compute horizontal basal velocity [m/a]
type='basal_drag';
if strcmpi(type, 'basal_drag')
	ub = sqrt(md.initialization.vx.^2 + md.initialization.vy.^2) / ...
        md.constants.yts;
elseif strcmpi(type, 'basal_dragx')
	ub = md.initialization.vx / md.constants.yts;
elseif strcmpi(type, 'basal_dragy')
	ub = md.initialization.vy / md.constants.yts;
end

% Compute basal drag in Pa
basal_drag = (max(md.constants.g * ...
    (md.materials.rho_ice * md.geometry.thickness + ...
    md.materials.rho_water * md.geometry.base), 0)...
    ).^r .* (md.friction.coefficient).^2 .* ub.^s;

% Compute basal shear heat production rate per square meter [J/(a*m^2)]
basal_shear_heating_rate = basal_drag .* ub;

% Compute vertical heat diffusion
vertical_heat_diffusion = 0;%...
    %md.materials.thermalconductivity * dT_dz;

% Find basal melt rate
basal_melt_rate = ...
    (md.basalforcings.geothermalflux + ...
    basal_shear_heating_rate + ...
    vertical_heat_diffusion) / ...
    (md.materials.latentheat * ... % latent heat in J/kg
    md.materials.rho_ice);

clear s r;


%% Calculate hydrology
effective_pressure = zeros(length(md.geometry.thickness), 1);

water_pressure = ...
    md.materials.rho_ice * md.constants.g * md.geometry.thickness - ...
    effective_pressure;

hydro_potential = ...
    md.materials.rho_water * md.constants.g * md.geometry.base + ...
    water_pressure;

%[hydro_potential_gradient_x, hydro_potential_gradient_y] = ...
%    gradient(hydro_potential);
%hydro_potential_gradient_norm = ...
%    sqrt(hydro_potential_gradient_x.^2 + hydro_potential_gradient_y.^2);

%% Post visualization
plotmodel(md, 'nlines', 3, 'ncols', 3, ...
    'unit#all', 'km', 'axis#all', 'equal', ...
    'xlim#all', [min(md.mesh.x) max(md.mesh.x)] / 10^3, ...
    'ylim#all', [min(md.mesh.y) max(md.mesh.y)] / 10^3, ...
    'FontSize#all', 12, ...
    'colormap#all', 'parula', ...
    'data', md.initialization.vel, ...
    'title', 'Observed velocity', ...
    'data', md.results.StressbalanceSolution.Vel, ...
    'title', 'Modeled Velocity', ...
    'colorbar#all', 'on', 'colorbartitle#1-2', '[m/yr]', ...
    'caxis#1-2', ([1.5, 4000]), ...
    'log#1-2', 10, ...
    'data', md.geometry.base, ...
    'title', 'Bed elevation', ...
    'colorbartitle#3', '[m]', ...
    'data', md.results.StressbalanceSolution.FrictionCoefficient, ...
    'title', 'Friction Coefficient', ...
    'title', 'SMB', 'data', md.smb.mass_balance, ...
    'title', 'Geothermal heatflux', 'data', md.basalforcings.geothermalflux, ...
    'title', 'Hydropotential', 'data', hydro_potential, ...
    'title', 'Driving stress [kPa]', 'data', 'driving_stress', ...
    'title', 'Basal drag [kPa]', 'data', 'basal_drag', ...
    'title', 'Basal melt rate [m/a]', 'data', 'basal_drag' ...
    );

saveas(gcf, 'figures/model_combined')
saveas(gcf, 'figures/model_combined.pdf')

% plotmodel(md, 'nlines', 1, 'ncols', 2, ...
%     'unit#all', 'km', 'axis#all', 'equal', ...
%     'xlim#all', [min(md.mesh.x) max(md.mesh.x)] / 10^3, ...
%     'ylim#all', [min(md.mesh.y) max(md.mesh.y)] / 10^3, ...
%     'FontSize#all', 12, ...
%     'colormap#all', 'parula', ...
%     'title', 'Basal drag [kPa]', 'data', 'basal_drag' ...
%     );

plotmodel(md, 'nlines', 1, 'ncols', 1, ...
    'unit#all', 'km', 'axis#all', 'equal', ...
    'xlim#all', [min(md.mesh.x) max(md.mesh.x)] / 10^3, ...
    'ylim#all', [min(md.mesh.y) max(md.mesh.y)] / 10^3, ...
    'FontSize#all', 12, ...
    'log', 10, ...
    'colormap#all', 'parula', ...
    'title', 'Basal melt rate [m/a]', 'data', basal_melt_rate ...
    );

%% Cleanup time
clear plot_data_sets ...
    plot_meshes ...
    plot_geometry ...
    plot_grounding_line ...
    plot_friction_coefficient ...
    stress_balance


