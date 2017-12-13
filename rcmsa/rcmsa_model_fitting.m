
function [epar, elabel] = rcmsa_model_fitting(data, xy, model_type, param)
% function [epar elabel] = rcmsa_model_fitting(data, xy, model_type, param)
% estimate the mutiple instaces of a geometric model given the input data.
% Input
% data      : [dxN] normalized data (d is dimension of each datum i.e. d = 6 for homography estimation, N is the number of data points) 
% xy        : [dxN] raw data
% param     : input tuning parameters
% param.sig : Standard deviation of noise (inlier threshold)
% param.bet : Model complextiy penalty (This parameter will control the number of output structures)
% param.sa  : Simulated Annealing Schedule (e.g, sa = 0.999)
% param.M   : Max number of iterations (e.g., M = 1000)
% param.K   : Patch size to update the weight (e.g., K = 20)

% model_type: model to be estimated (e.g., fundamental matrix, homography matrix)

% Output
% epar : Estimated parameters
% label: Segmentation

%---Measure computing time------------------------------------------------%
tic;
%-------------------------------------------------------------------------%


%---Compute model complexity beta parameter-------------------------------%
param.bet = param.min_inliers;

%------Get model parameters-----------------------------------------------%
[fitfn, resfn, degenfn, psize, numpar] = getModelPara(model_type);
%-------------------------------------------------------------------------%

%-------Parameters--------------------------------------------------------%
N   = size(data,2);           % Number of data points
M   = param.M;                % Number of iterations
K   = param.K;                % Patch size to update the weights
mv  = [0.5 0.5];              % Birth and death probabilities
par = zeros(numpar,M*mv(1));  % Parameters allocation
res = zeros(N, M*mv(1));      % Residuals allocation
eng = zeros(M,1);             % Engeries allocation
%-------------------------------------------------------------------------%

%------------Create Adjacency Graph by Delaunay triagulation--------------%
[edge] = adjacenygraph(xy);     % Create graph
ne     = length(edge);          % Number of edges
E      = sparse(edge(:,1),edge(:,2),ones(ne,1),N,N); % Sparse adjacency matrix
%-------------------------------------------------------------------------%


%-------------------------Initialisation----------------------------------%
%-------------------------Edge weights------------------------------------%
weight      = zeros(ne,1);
weight(:,1) = 0.25;              % All weights are initalised to 0.25
%-------------------------------------------------------------------------%

smoothcost = 0.1;      % Smooth cost 
r0         = ones(1,N);    % Residual for dummy model (outlier model)
res(:,1)   = r0;           % Put outlier cost to residual pool
f          = ones(N,1);    % f is hidden label variables
J          = sum(r0) + param.bet; % Current Energy
lnew       = 1;            % New label
dcost      = res(:,1);     % Current data cost
numm       = 1;            % Current number of models
pcost      = r0;           % Cost of each points w.r.t their label.
epar       = [];           % Estimated paramters 
%-----------------------End of initalisation------------------------------%

%--------Simulated annealing to minimise energy---------------------------%
% Inited temperature 
T = 1000;

% Loop through a number of iteration
%cpu_time = [];
%est_pars = {};
for m=1:M
    
    % Random select birth and death process
    % If the number of model is less than 2, choose 'birth'
    if numm < 3
        toss = 1;
    else
        toss = randsample(2,1, 'true', mv);
    end
    
    if toss == 1 % Do birth process
        
        % New label
        lnew = lnew+1;
        
        % Sample a new hypothesis
        % Sample a connected component R using RCM method
        if param.rcm_sampling == 1
            V_R = rcm_sampling(data, psize,degenfn,f,edge,weight,pcost);
        else
            V_R = random_sampling(data, psize, degenfn);
        end
        
        % Compute putative model and residuals
        p = feval(fitfn,data(:, V_R));
        r = feval(resfn,p,data);
        r = r./param.sig;
        
        % Save to parameter and residual pool
        p = reshape(p, numpar, 1);
        res(:,lnew) = r;
        par(:,lnew) = p;
        
        % Add to the current configuration
        dcost_temp = [dcost r];
        epar_temp = [epar p];
        numm_temp = numm + 1;
        
    else % Do Death Process
        
        % Select randomly one label
        a = randsample(2:numm, 1);
        
        % Remove from the current configuration
        dcost_temp = dcost;
        dcost_temp(:,a) = [];
        epar_temp = epar;
        epar_temp(:, a-1) = [];
        numm_temp = numm - 1;
        
    end
    
    % Extract labels based on alpha_expansion method
    [f_temp, J_temp, pcost] = get_labels(E, dcost_temp, smoothcost);
    
    % Compute the new energy
    J_temp = double(J_temp + numm_temp*param.bet);
    
    % Calculate acceptance probability           
    alpha = exp((-J_temp + J)/T);
    
    % Accept new configuration probabilistically
    if rand < alpha
        % Accept and do local refinement
        [epar, dcost] = local_refine(data, f_temp, epar_temp, dcost_temp, numm_temp, psize, fitfn, resfn, numpar, param.sig);
                
        % Re-compute labels and energy
        [f, J, pcost] = get_labels(E, dcost, smoothcost);
        
        % Current number of models
        ulabels = unique(f);
        numm = length(ulabels);
        dcost = dcost(:, ulabels);
        ulabels = setdiff(ulabels, 1);
        epar = epar(:, ulabels - 1);
        J = double(J + numm*param.bet);      
    end
    
    % Save history of energies
    eng(m) = J;
    
    % Decrease temperature
    T = T*param.sa;
    
    % Update the weights
    if mod(m,K) == 0 && m >= K
        [weight] = update_weights(res,lnew, ne, edge);
    end
   
    % Check convergence
    % A more complicated convergence criteria can be used
    if m>200 && std(eng(m-200:m)) < 0.001
        break;
    end
   
end

%---- End of Simulated Annealing Optimisation-----------------------------%
% Output estimated parameters
elabel = f;
if size(epar,2)>1 && sum(epar(:,1))==0
    epar(:,1) = []; % Remove outlier model
end
toc;
% Display energy evolution
% figure(10); plot(eng);drawnow;

end

% This function is used to update the edge weights of the graph
function [weight] = update_weights(res,num_hyp, nedge, edge)
% Input   :
% res     : residual matrix
% num_hyp : number of hypotheses in matrix res
% nedge   : number of edges
% edge    : set of edges of adjcancy graph

% Output  :
% weight  : updated weight w.r.t residual matrix

% Computer preference analysis
[ ~, ordering ] = sort(res(:,1:num_hyp),2);

% Similarity matrix from intersection - becomes edge probabilities for MRF.
weight = ones(nedge,1);
for i=1:nedge    
    weight(i,1)=computeIntersection(ordering(edge(i,1),:)',ordering(edge(i,2),:)',ceil(0.1*num_hyp));
end

weight =max((weight-0.4)./(1-0.4),0);   % Offset.

end

% This function is used to create an adjacency graph from input data
function [edge] = adjacenygraph(data)
% Input:
% data: [dxN] d: dimention of each point, N: the number of data

% Output:
% edges: a list of connected edges

% Transpose data
data = data'; 

% Use PCA to extract the first two principle components
[pc,~,~,~] = pca(data);

% Project data to the first two principle components
new_data = data*pc(:,1:2);
x = new_data(:,1);
y = new_data(:,2);

%x = data(:,1);
%y = data(:,2);

% Create adjacency graph using Delaunay Triangulation
warning('off','all')
dt = delaunay(x,y);
trep = triangulation(dt, x, y);

% Get a set of edges
edge = edges(trep);

end

% This function is used to refine the current parameters
function [epar, dcost] = local_refine(data, label, epar, dcost, numm, psize, fitfn, resfn, npar, sig)

% Loop through number of models
% The first model is (often) an outlier (dummy) model
for n=2:numm 
    % Extract points associated with model n
    pts = (label==n);
    % Check whether model is valid
    if sum(pts) >= psize
        p = feval(fitfn,data(:, pts));
        if (isempty(p))
            continue;
        end
        p = reshape(p, npar, 1);
        if length(p) == npar
            r = feval(resfn,p,data);
            r = r./sig;
            epar(:,n-1)  = p;
            dcost(:,n) = r;
        end
    end       
end

end



