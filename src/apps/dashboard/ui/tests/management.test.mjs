import assert from 'node:assert/strict';
import {test} from 'node:test';
import {sections, operationLocations, inventoryDomains, sectionGroups, needsExistingDomain,
    needsExistingEndpoint, operationDefaults, submittedArguments} from '../src/management.js';

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
