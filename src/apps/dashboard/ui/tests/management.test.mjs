import assert from 'node:assert/strict';
import {test} from 'node:test';
import {sections, operationLocations, inventoryDomains, sectionGroups, needsExistingDomain,
    needsExistingEndpoint, operationDefaults, submittedArguments, runtimeDeploymentOptions,
    runtimeDeploymentFields, changedOperationValues} from '../src/management.js';

const domainField = {name: 'domain', required: true};
const endpointField = {name: 'endpoint', required: true};
const action = (id, fields = [], extra = {}) => ({id, title: id, fields, ...extra});

test('registered domain selection preserves domains without endpoints and never invents a root endpoint', () => {
    const result = inventoryDomains({domains: [{domain: 'empty.example', type: 'runtime'}], endpoints: [
        {domain: 'api.example', label: 'v2', type: 'static'}, {domain: 'api.example', label: 'v3', type: 'static'},
    ]});
    assert.deepEqual(result.map(domain => [domain.domain, domain.endpoints.map(endpoint => endpoint.label)]), [
        ['api.example', ['v2', 'v3']], ['empty.example', []],
    ]);
});

test('domain menus offer operations for the selected domain kind and publication state', () => {
    const operations = ['domain.go_live', 'domain.stage', 'endpoint.add_static', 'endpoint.add_runtime', 'runtime.cache', 'pages.docs'].map(id => action(id, [domainField]));
    const ids = domain => sectionGroups(operations, 'domains', domain).flatMap(group => group.operations.map(spec => spec.id));
    assert.deepEqual(ids({type: 'runtime', live: false}), ['domain.go_live', 'endpoint.add_runtime', 'runtime.cache', 'pages.docs']);
    assert.deepEqual(ids({type: 'static', live: true}), ['domain.stage', 'endpoint.add_static', 'pages.docs']);
});

test('deployment accepts new names while existing endpoint operations require inventory selection', () => {
    assert.equal(needsExistingDomain(action('domain.deploy_static', [domainField, endpointField])), false);
    assert.equal(needsExistingDomain(action('dashboard.enable', [domainField])), false);
    assert.equal(needsExistingDomain(action('domain.apply', [domainField])), true);
    assert.equal(needsExistingEndpoint(action('endpoint.add_static', [domainField, endpointField])), false);
    assert.equal(needsExistingEndpoint(action('endpoint.change_source', [domainField, endpointField])), true);
});

test('CLI entry points and new catalogue actions remain reachable without a flat dropdown', () => {
    assert.deepEqual(operationLocations(action('system.self_update')), [['self-update', 'Manager checkout']]);
    assert.deepEqual(operationLocations(action('logs.view', [domainField])), [['logs', 'Domain logs'], ['domains', 'Logs']]);
    assert.deepEqual(operationLocations(action('logs.reset')), [['logs', 'History']]);
    assert.deepEqual(operationLocations(action('pages.upload_icon')), [['settings', 'Icons'], ['domains', 'Pages and OpenAPI']]);
    for (const spec of [action('future.diagnostic'), action('future.domain', [domainField])]) {
        assert.ok(operationLocations(spec).every(([section]) => sections.some(item => item.id === section)));
        assert.ok(sections.some(section => sectionGroups([spec], section.id).some(group => group.operations.includes(spec))));
    }
});

test('current access and repository settings initialize the selected action without leaking prior form values', () => {
    const domain = {domain: 'api.example', settings: {ACCESS_MODE: 'open'}};
    assert.deepEqual(operationDefaults(action('access.mode', [domainField, {name: 'mode', default: 'metered'}]), {domain}), {domain: 'api.example', mode: 'open'});
    const endpoint = {label: 'v3', endpoint_settings: {REPO_URL: 'git@example.org:team/data.git', REPO_REF: 'main', REPO_PATH: 'data'}};
    const spec = action('endpoint.change_source', [domainField, endpointField, {name: 'repository'}, {name: 'ref'}, {name: 'source_path'}]);
    assert.deepEqual(operationDefaults(spec, {domain, endpoint}), {domain: 'api.example', endpoint: 'v3', repository: 'git@example.org:team/data.git', ref: 'main', source_path: 'data'});
});

test('submission retains intentional empty settings and boolean false but excludes stale arguments', () => {
    const spec = action('runtime.set', [domainField, {name: 'endpoint'}, {name: 'value', allow_empty: true}, {name: 'force'}]);
    assert.deepEqual(submittedArguments(spec, {domain: 'query.example', endpoint: '', value: '', force: false, stale: 'secret'}), {domain: 'query.example', value: '', force: false});
});

const runtimeMetadata = {
    runtime_kinds: {query: {versions: ['v2', 'v3'], default_version: 'v2'}, search: {versions: ['v2', 'v3'], default_version: 'v2'},
        study: {versions: ['v4'], default_version: 'v4'}},
    repositories: [
        {value: '/srv/getbible/api.example', label: 'api.example (v2)', version: 'v2'},
        {value: '/srv/getbible/api.example', label: 'api.example (v3)', version: 'v3'},
        {value: '/srv/getbible/bible.example', label: 'bible.example (v3)', version: 'v3'},
    ],
};
const deployRuntime = action('domain.deploy_runtime', [domainField, {name: 'kind'}, {name: 'version'}, {name: 'repository'}], runtimeMetadata);
const addRuntime = action('endpoint.add_runtime', [domainField, endpointField, {name: 'repository'}], runtimeMetadata);

test('runtime choices and defaults come from manifests without forcing the newest version', () => {
    const initial = operationDefaults(deployRuntime);
    assert.equal(initial.version, '');
    assert.equal(runtimeDeploymentFields(deployRuntime, initial).find(field => field.name === 'version').disabled, true);
    const query = changedOperationValues(deployRuntime, initial, 'kind', 'query');
    assert.equal(query.version, 'v2');
    const options = runtimeDeploymentOptions(deployRuntime, query);
    assert.deepEqual(options.kinds, ['query', 'search', 'study']);
    assert.deepEqual(options.versions, ['v2', 'v3']);
    assert.equal(changedOperationValues(deployRuntime, query, 'kind', 'study').version, 'v4');
});

test('runtime repository selection includes only sources published for the selected version', () => {
    const v2 = runtimeDeploymentOptions(deployRuntime, {kind: 'query', version: 'v2'});
    assert.deepEqual(v2.repositories.map(repository => repository.label), ['api.example (v2)']);
    const v3 = runtimeDeploymentOptions(deployRuntime, {kind: 'search', version: 'v3'});
    assert.deepEqual(v3.repositories.map(repository => repository.label), ['api.example (v3)', 'bible.example (v3)']);
    assert.equal(runtimeDeploymentFields(deployRuntime, {kind: 'query', version: 'v3'}).find(field => field.name === 'repository').type, 'runtime_repository');
});

test('changing kind, version or endpoint clears a previously selected or custom source', () => {
    for (const [spec, name, value, domain] of [
        [deployRuntime, 'version', 'v3'], [deployRuntime, 'kind', 'search'],
        [addRuntime, 'endpoint', 'v3', {kind: 'query', endpoints: []}],
    ]) {
        const previous = {kind: 'query', version: 'v2', endpoint: 'v2', repository: '/srv/custom', _repositoryMode: 'manual'};
        const next = changedOperationValues(spec, previous, name, value, domain);
        assert.equal(next.repository, undefined);
        assert.equal(next._repositoryMode, undefined);
        assert.equal(previous.repository, '/srv/custom');
    }
    assert.equal(changedOperationValues(deployRuntime, {kind: 'query', version: 'v2', repository: '/srv/custom'}, 'version', 'v2').repository, '/srv/custom');
});

test('adding a runtime endpoint uses its domain kind and excludes existing versions', () => {
    const domain = {domain: 'query.example', kind: 'query', endpoints: [{label: 'v2'}]};
    const defaults = operationDefaults(addRuntime, {domain});
    assert.deepEqual(defaults, {domain: 'query.example', endpoint: 'v3'});
    const options = runtimeDeploymentOptions(addRuntime, defaults, domain);
    assert.deepEqual(options.versions, ['v3']);
    assert.deepEqual(options.repositories.map(repository => repository.version), ['v3', 'v3']);
    domain.endpoints.push({label: 'v3'});
    assert.deepEqual(runtimeDeploymentOptions(addRuntime, {}, domain).versions, []);
    assert.equal(runtimeDeploymentFields(addRuntime, {}, domain).find(field => field.name === 'endpoint').disabled, true);
});

test('automatic sources omit the repository argument and custom paths pass through unchanged', () => {
    assert.deepEqual(submittedArguments(deployRuntime, {domain: 'query.example', kind: 'query', version: 'v3', repository: '', _repositoryMode: 'published'}),
        {domain: 'query.example', kind: 'query', version: 'v3'});
    assert.deepEqual(submittedArguments(deployRuntime, {domain: 'query.example', kind: 'query', version: 'v3', repository: '/mnt/bibles/local-v3', _repositoryMode: 'manual'}),
        {domain: 'query.example', kind: 'query', version: 'v3', repository: '/mnt/bibles/local-v3'});
});

test('a runtime root endpoint prevents adding version folders to the same domain', () => {
    const domain = {domain: 'query.example', kind: 'query', endpoints: [{label: 'root'}]};
    const defaults = operationDefaults(addRuntime, {domain});
    const options = runtimeDeploymentOptions(addRuntime, defaults, domain);
    assert.equal(options.rootEndpoint, true);
    assert.deepEqual(options.versions, []);
    assert.deepEqual(options.repositories, []);
    assert.equal(defaults.endpoint, '');
    const field = runtimeDeploymentFields(addRuntime, defaults, domain).find(field => field.name === 'endpoint');
    assert.equal(field.disabled, true);
    assert.match(field.description, /root endpoint.*cannot coexist with version folders/);
});
