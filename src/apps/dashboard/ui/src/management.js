export const sections = [
    {id: 'domains', title: 'Domains', detail: 'Status, endpoints, pages, access and runtime settings'},
    {id: 'deploy', title: 'Deploy a new domain', detail: 'Prepare a static, runtime or MCP domain'},
    {id: 'go-live', title: 'Go live', detail: 'Activate a staged domain'},
    {id: 'self-update', title: 'Update manager', detail: 'Update the native manager checkout'},
    {id: 'update', title: 'Upgrade targets', detail: 'Review changes, select targets and retry incomplete upgrades'},
    {id: 'analytics', title: 'Traffic analytics', detail: 'Run a traffic report'},
    {id: 'dashboard', title: 'Private dashboard', detail: 'Domain, password, sessions and blocked addresses'},
    {id: 'logs', title: 'Logs', detail: 'Domain diagnostics, archives and rotation'},
    {id: 'settings', title: 'Settings', detail: 'Environment, notifications, Cloudflare token and icons'},
    {id: 'system', title: 'System', detail: 'Host checks, dependencies and resource allocation'},
];

export const operationId = spec => spec.id || spec.operation || spec.name;
export function operationFields(spec) {
    const fields = spec?.fields || spec?.parameters || [];
    return Array.isArray(fields) ? fields : Object.entries(fields).map(([name, field]) => ({name, ...field}));
}

// Match the CLI's entry points; the broker remains the source of available actions.
export function operationLocations(spec) {
    const id = operationId(spec);
    if (id.startsWith('domain.deploy_')) return [['deploy', 'New domain']];
    if (id === 'domain.go_live') return [['go-live', 'Activation'], ['domains', 'Publication']];
    if (id === 'system.self_update') return [['self-update', 'Manager checkout']];
    if (id === 'system.update') return [['update', 'Review eligible targets']];
    if (id === 'analytics') return [['analytics', 'Traffic report']];
    if (id.startsWith('dashboard.')) {
        const group = ['dashboard.sessions', 'dashboard.revoke'].includes(id) ? 'Sessions' : id === 'dashboard.blocks' ? 'Blocked addresses' : 'Dashboard settings';
        return [['dashboard', group]];
    }
    if (id.startsWith('logs.')) {
        if (id === 'logs.rotate') return [['logs', 'Rotation']];
        if (id === 'logs.reset') return [['logs', 'History']];
        return [['logs', 'Domain logs'], ['domains', 'Logs']];
    }
    if (id.startsWith('settings.')) return [['settings', 'Environment and defaults']];
    if (id.startsWith('telegram.')) return [['settings', 'Telegram notifications']];
    if (id === 'cloudflare.token') return [['settings', 'Cloudflare API token']];
    if (['system.icons', 'system.favicon', 'system.logo'].includes(id)) return [['settings', 'Icons']];
    if (id === 'pages.upload_icon') return [['settings', 'Icons'], ['domains', 'Pages and OpenAPI']];
    if (['cloudflare.verify', 'cloudflare.refresh_ips'].includes(id)) return [['system', 'Cloudflare origin tools']];
    if (id.startsWith('resources.')) return [['system', 'Resource allocation']];
    if (id === 'runtime.versions') return [['system', 'Python versions']];
    if (operationFields(spec).some(field => field.name === 'domain')) {
        let group = 'Other domain operations';
        if (['domain.status', 'domain.verify'].includes(id)) group = 'Status and health';
        else if (id === 'domain.stage') group = 'Publication';
        else if (['domain.apply', 'domain.update'].includes(id)) group = 'Apply configuration';
        else if (id === 'domain.remove') group = 'Remove domain';
        else if (id.startsWith('endpoint.')) group = 'Endpoints and repositories';
        else if (id === 'access.mode') group = 'Access mode';
        else if (id === 'access.limits') group = 'Anonymous caller limits';
        else if (id.startsWith('token.')) group = 'Bearer tokens';
        else if (id.startsWith('certificate.')) group = 'Certificate';
        else if (id.startsWith('cloudflare.')) group = 'Cloudflare';
        else if (id.startsWith('pages.')) group = 'Pages and OpenAPI';
        else if (id.startsWith('mcp.')) group = 'MCP service';
        else if (id === 'runtime.set') group = 'Runtime settings';
        else if (id === 'runtime.cache') group = 'Translation memory';
        else if (id.startsWith('runtime.')) group = 'Runtime services';
        return [['domains', group]];
    }
    return [['system', id.startsWith('system.') ? 'Host maintenance' : spec.category || 'Other operations']];
}

export function inventoryDomains(inventory) {
    const domains = new Map((inventory?.domains || []).map(domain => [domain.domain, {...domain, endpoints: []}]));
    for (const endpoint of inventory?.endpoints || []) {
        if (!domains.has(endpoint.domain)) domains.set(endpoint.domain, {...endpoint, endpoints: []});
        domains.get(endpoint.domain).endpoints.push(endpoint);
    }
    return [...domains.values()].sort((a, b) => a.domain.localeCompare(b.domain));
}

export function supportsDomain(spec, domain) {
    if (!domain) return true;
    const id = operationId(spec);
    const runtime = domain.type === 'runtime';
    const staticDomain = domain.type === 'static';
    if (Array.isArray(spec.domain_types) && !spec.domain_types.includes(domain.type)) return false;
    if (id.startsWith('mcp.')) return domain.type === 'mcp';
    if (id.startsWith('runtime.') || ['endpoint.add_runtime', 'endpoint.default'].includes(id)) return runtime;
    if (['endpoint.add_static', 'endpoint.change_source', 'endpoint.sync', 'endpoint.deploy_key', 'endpoint.repo_access', 'endpoint.filetypes'].includes(id)) return staticDomain;
    if (['endpoint.remove', 'pages.docs', 'pages.openapi', 'pages.write'].includes(id)) return staticDomain || runtime;
    if (id === 'domain.go_live') return !domain.live;
    if (id === 'domain.stage') return domain.live;
    return true;
}

export function sectionGroups(operations, section, domain) {
    const groups = new Map();
    for (const spec of operations) {
        if (!supportsDomain(spec, domain)) continue;
        const location = operationLocations(spec).find(([key]) => key === section);
        if (!location) continue;
        if (!groups.has(location[1])) groups.set(location[1], []);
        groups.get(location[1]).push(spec);
    }
    return [...groups].map(([title, operations]) => ({title, operations}));
}

export function needsExistingDomain(spec) {
    return operationFields(spec).some(field => field.name === 'domain' && field.required) &&
        !operationId(spec).startsWith('domain.deploy_') && operationId(spec) !== 'dashboard.enable';
}

export function needsExistingEndpoint(spec) {
    return operationFields(spec).some(field => field.name === 'endpoint') &&
        !operationId(spec).startsWith('domain.deploy_') && !operationId(spec).startsWith('endpoint.add_');
}

export function endpointScopeLabel(spec) {
    const id = operationId(spec);
    if (id.startsWith('pages.')) return 'Domain page';
    if (id === 'logs.view') return 'Domain logs';
    return 'All endpoints';
}

export function runtimeDeploymentOptions(spec, values = {}, domain) {
    const id = spec && operationId(spec);
    if (!spec?.runtime_kinds || !['domain.deploy_runtime', 'endpoint.add_runtime'].includes(id)) return null;
    const kind = id === 'endpoint.add_runtime' ? domain?.kind : values.kind;
    const implementation = spec.runtime_kinds[kind];
    const served = id === 'endpoint.add_runtime' ? new Set((domain?.endpoints || []).map(endpoint => endpoint.label)) : new Set();
    const rootEndpoint = served.has('root');
    const versions = rootEndpoint ? [] : (implementation?.versions || []).filter(version => !served.has(version));
    const defaultVersion = versions.includes(implementation?.default_version) ? implementation.default_version : versions[0] || '';
    const versionField = id === 'endpoint.add_runtime' ? 'endpoint' : 'version';
    const version = values[versionField] || defaultVersion;
    return {kind, kinds: Object.keys(spec.runtime_kinds), versions, defaultVersion, versionField, version, rootEndpoint,
        repositories: (spec.repositories || []).filter(repository => repository.version === version)};
}

export function runtimeDeploymentFields(spec, values, domain) {
    const options = runtimeDeploymentOptions(spec, values, domain);
    return operationFields(spec).map(field => {
        if (!options) return field;
        if (field.name === 'kind') return {...field, choices: options.kinds};
        if (field.name === options.versionField) return {...field, label: 'API version', choices: options.versions,
            disabled: !options.kind || !options.versions.length,
            description: !options.kind ? 'Choose a runtime kind to see its API versions.' : options.rootEndpoint ? 'This domain serves a root endpoint, which cannot coexist with version folders.' : !options.versions.length ? 'This domain already serves every available version.' : field.description};
        if (field.name === 'repository') return {...field, type: 'runtime_repository', label: 'Local Bible source',
            repositories: options.repositories, disabled: !options.kind || !options.versions.length};
        return field;
    });
}

export function changedOperationValues(spec, values, name, value, domain) {
    const next = {...values, [name]: value};
    const options = runtimeDeploymentOptions(spec, next, domain);
    if (options && values[name] !== value && ['kind', 'version', 'endpoint', 'domain'].includes(name)) {
        delete next.repository;
        delete next._repositoryMode;
        if (name === 'kind' || name === 'domain') next[options.versionField] = options.defaultVersion;
    }
    return next;
}

export function operationDefaults(spec, {domain, endpoint} = {}) {
    const fields = operationFields(spec);
    const values = Object.fromEntries(fields.filter(field => field.default !== undefined).map(field => [field.name, field.default]));
    if (domain && fields.some(field => field.name === 'domain')) values.domain = domain.domain;
    if (endpoint !== undefined && fields.some(field => field.name === 'endpoint')) values.endpoint = endpoint?.label || '';
    const settings = domain?.settings || {};
    const endpointSettings = endpoint?.endpoint_settings || {};
    const id = operationId(spec);
    const currentFields = id === 'access.mode' ? {mode: settings.ACCESS_MODE} :
        id === 'access.limits' ? {rate: settings.RATE_PER_SECOND, burst: settings.RATE_BURST, hour: settings.QUOTA_HOUR, day: settings.QUOTA_DAY, connections: settings.CONN_LIMIT} :
        id === 'endpoint.change_source' ? {repository: endpointSettings.REPO_URL, ref: endpointSettings.REPO_REF, source_path: endpointSettings.REPO_PATH} :
        id === 'cloudflare.mode' ? {value: settings.CLOUDFLARE_MODE} :
        id === 'cloudflare.cache' ? {value: settings.CLOUDFLARE_CACHE} : {};
    const defaults = {...values, ...Object.fromEntries(Object.entries(currentFields).filter(([, value]) => value !== undefined))};
    const runtime = runtimeDeploymentOptions(spec, defaults, domain);
    if (runtime) defaults[runtime.versionField] = runtime.defaultVersion;
    return defaults;
}

export function submittedArguments(spec, values) {
    // Restrict submissions to the current action; preserve intentional empty settings.
    return Object.fromEntries(operationFields(spec).filter(field => values[field.name] !== undefined &&
        (values[field.name] !== '' || field.allow_empty)).map(field => [field.name, values[field.name]]));
}
