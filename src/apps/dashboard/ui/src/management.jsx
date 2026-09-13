import React, {useEffect, useMemo, useState} from 'react';
import {api, date} from './api.js';
import {Panel, Busy, Empty, Badge, DataTable, ErrorNotice} from './components.jsx';
import {sections, operationId, inventoryDomains, supportsDomain, sectionGroups,
    needsExistingDomain, needsExistingEndpoint, endpointScopeLabel, operationDefaults, submittedArguments,
    runtimeDeploymentOptions, runtimeDeploymentFields, changedOperationValues} from './management.js';

const rows = (value, key) => Array.isArray(value) ? value : value?.[key] || [];
const activeStatuses = new Set(['queued', 'waiting', 'running']);

function MenuCards({items, onSelect}) {
    return <div className="manage-grid">{items.map(item => <button type="button" className="manage-card" key={item.id || item.title} onClick={() => onSelect(item)}>
        <strong>{item.title}</strong>{item.detail && <small>{item.detail}</small>}{item.badge && <Badge tone={item.tone}>{item.badge}</Badge>}
    </button>)}</div>;
}

function OperationField({field, values, setValues, onError, domains, currentSettings, spec, selectedDomain}) {
    const change = value => setValues(previous => ({...changedOperationValues(spec, previous, field.name, value, selectedDomain),
        ...(field.name === 'key' && currentSettings ? {value: currentSettings[value] ?? ''} : {})}));
    const props = {className: 'form-control', 'aria-label': field.label || field.name, required: field.required && !field.allow_empty, disabled: field.disabled};
    let input;
    if (field.type === 'runtime_repository') {
        const manual = values._repositoryMode === 'manual';
        return <div>
            <label>{field.label}<select {...props} className="form-select" value={manual ? '__manual__' : values.repository || ''} onChange={event => {
                const value = event.target.value;
                setValues(previous => ({...previous, repository: value === '__manual__' ? '' : value,
                    _repositoryMode: value === '__manual__' ? 'manual' : 'published'}));
            }}>
                <option value="">Automatic local source</option>
                {field.repositories.map(repository => <option key={repository.value} value={repository.value}>{repository.label}</option>)}
                <option value="__manual__">Enter a local path…</option>
            </select></label>
            {manual && <label>Custom local path<input className="form-control" aria-label="Custom local path" type="text" required autoComplete="off" value={values.repository || ''} onChange={event => change(event.target.value)}/></label>}
            {field.description && <small>{field.description}</small>}
        </div>;
    } else if (field.type === 'file') {
        input = <input {...props} type="file" accept=".png,.jpg,.jpeg,.webp,.ico,.svg" onChange={event => {
            const file = event.target.files?.[0];
            if (!file) return;
            if (file.size > 1048576) {onError(new Error('Choose an image smaller than 1 MiB.')); event.target.value = ''; return;}
            const reader = new FileReader();
            reader.onload = () => setValues(previous => ({...previous, filename: file.name, [field.name]: String(reader.result).split(',')[1]}));
            reader.onerror = () => onError(new Error('The selected file could not be read.'));
            reader.readAsDataURL(file);
        }}/>;
    } else if (field.type === 'multiline') {
        input = <textarea {...props} rows={12} spellCheck="false" value={values[field.name] || ''} onChange={e => change(e.target.value)}/>;
    } else if (field.type === 'boolean') {
        input = <select aria-label={field.label || field.name} className="form-select" value={String(values[field.name] ?? false)} onChange={e => change(e.target.value === 'true')}><option value="false">No</option><option value="true">Yes</option></select>;
    } else if (field.name === 'domain' && !field.required) {
        input = <select aria-label={field.label || field.name} className="form-select" value={values.domain || ''} onChange={e => change(e.target.value)}><option value="">{field.scopeLabel || 'All domains'}</option>{domains.map(domain => <option key={domain.domain} value={domain.domain}>{domain.domain}</option>)}</select>;
    } else if (field.choices || field.enum) {
        input = <select {...props} className="form-select" value={values[field.name] ?? ''} onChange={e => change(e.target.value)}><option value="">Select…</option>{(field.choices || field.enum).map(choice => <option key={choice} value={choice}>{choice}</option>)}</select>;
    } else {
        input = <input {...props} type={field.secret ? 'password' : field.type === 'integer' ? 'number' : 'text'} autoComplete={field.secret ? 'new-password' : 'off'} value={values[field.name] ?? ''} onChange={e => change(field.type === 'integer' && e.target.value !== '' ? Number(e.target.value) : e.target.value)}/>;
    }
    return <label className={field.type === 'multiline' ? 'full-width' : undefined}>{field.label || field.name}{input}{field.description && <small>{field.description}</small>}</label>;
}

export default function Management({execute, onError, onDetail, refresh, initialSection = ''}) {
    const [catalogue, setCatalogue] = useState(null);
    const [inventory, setInventory] = useState(null);
    const [loadError, setLoadError] = useState(null);
    const [jobs, setJobs] = useState(null);
    const [management, setManagement] = useState(null);
    const [navigation, setNavigation] = useState({section: initialSection, domain: '', group: '', operation: '', endpoint: undefined});
    const [values, setValues] = useState({});
    useEffect(() => {
        let stopped = false;
        setLoadError(null);
        Promise.allSettled([api('operations'), api('endpoints')]).then(results => {
            if (stopped) return;
            if (results[0].status === 'fulfilled') setCatalogue(results[0].value);
            if (results[1].status === 'fulfilled') setInventory(results[1].value);
            const failed = results.find(result => result.status === 'rejected');
            if (failed) {setLoadError(failed.reason); onError(failed.reason);}
        });
        return () => {stopped = true;};
    }, [refresh]);
    useEffect(() => {
        let stopped = false;
        let timer;
        async function poll() {
            try {
                const [data, state] = await Promise.all([api('jobs'), api('management/state')]);
                if (!stopped) {setJobs(data); setManagement(state);}
            } catch (error) {if (!stopped) onError(error);}
            if (!stopped) timer = setTimeout(poll, 2000);
        }
        poll();
        return () => {stopped = true; clearTimeout(timer);};
    }, [refresh]);
    const operations = rows(catalogue, 'operations');
    const domains = useMemo(() => inventoryDomains(inventory), [inventory]);
    const selectedDomain = domains.find(domain => domain.domain === navigation.domain);
    const selectedEndpoint = selectedDomain?.endpoints.find(endpoint => endpoint.label === navigation.endpoint);
    const spec = operations.find(item => operationId(item) === navigation.operation);
    const fields = runtimeDeploymentFields(spec, values, selectedDomain);
    const runtime = runtimeDeploymentOptions(spec, values, selectedDomain);
    const runtimeUnavailable = Boolean(runtime && (!runtime.kind || !runtime.versions.length));
    const section = sections.find(item => item.id === navigation.section);
    const groups = sectionGroups(operations, navigation.section, selectedDomain);
    const selectedGroup = groups.find(group => group.title === navigation.group);
    const domainFirst = ['domains', 'go-live'].includes(navigation.section);
    const choosingDomain = Boolean(navigation.section && !navigation.domain && (domainFirst || (spec && needsExistingDomain(spec))));
    const choosingEndpoint = Boolean(spec && !choosingDomain && needsExistingEndpoint(spec) && navigation.endpoint === undefined);
    const paused = management?.accepting_jobs === false;
    const domainMissing = Boolean(navigation.domain && inventory && !selectedDomain);
    const endpointMissing = Boolean(navigation.endpoint && inventory && !selectedEndpoint);
    const visibleFields = fields.filter(field => !(field.name === 'domain' && navigation.domain) &&
        !(field.name === 'endpoint' && needsExistingEndpoint(spec)) && !(field.name === 'filename' && fields.some(item => item.type === 'file')));

    function navigate(next) {
        setNavigation(next);
        const action = operations.find(item => operationId(item) === next.operation);
        const domain = domains.find(item => item.domain === next.domain);
        const endpoint = next.endpoint === undefined ? undefined : domain?.endpoints.find(item => item.label === next.endpoint) || null;
        setValues(action ? operationDefaults(action, {domain, endpoint}) : {});
    }
    function chooseSection(item) {
        const availableGroups = sectionGroups(operations, item.id);
        const onlyGroup = availableGroups.length === 1 ? availableGroups[0] : undefined;
        navigate({section: item.id, domain: '', group: onlyGroup?.title || '',
            operation: onlyGroup?.operations.length === 1 ? operationId(onlyGroup.operations[0]) : '', endpoint: undefined});
    }
    function chooseDomain(item) {navigate({...navigation, domain: item.id, endpoint: undefined});}
    function chooseOperation(item) {navigate({...navigation, operation: item.id, endpoint: undefined});}
    function submit(event) {
        event.preventDefault();
        if (!spec || paused || domainMissing || endpointMissing || runtimeUnavailable) return;
        execute(operationId(spec), submittedArguments(spec, values), {title: spec.title, description: spec.description});
    }
    const crumbs = [{label: 'Manage', action: () => navigate({section: '', domain: '', group: '', operation: '', endpoint: undefined})}];
    if (section) crumbs.push({label: section.title, action: () => chooseSection(section)});
    if (navigation.domain && domainFirst) crumbs.push({label: navigation.domain, action: () => navigate({...navigation, group: '', operation: '', endpoint: undefined})});
    if (navigation.group) crumbs.push({label: navigation.group, action: () => navigate({...navigation, operation: '', endpoint: undefined})});
    if (spec) crumbs.push({label: spec.title, action: () => navigate({...navigation, domain: domainFirst ? navigation.domain : '', endpoint: undefined})});
    if (navigation.domain && !domainFirst) crumbs.push({label: navigation.domain, action: () => navigate({...navigation, endpoint: undefined})});
    if (spec && navigation.endpoint !== undefined) crumbs.push({label: navigation.endpoint || endpointScopeLabel(spec)});

    let content;
    if (!catalogue) content = loadError ? <Empty>Management actions could not be loaded. Use Refresh all to retry.</Empty> : <Busy/>;
    else if (!operations.length) content = <Empty>No management operations were returned by the broker.</Empty>;
    else if (!section) content = <MenuCards items={sections.filter(item => sectionGroups(operations, item.id).length)} onSelect={chooseSection}/>;
    else if (domainMissing || endpointMissing) content = <Empty>This {domainMissing ? 'domain' : 'endpoint'} is no longer registered. Select another from the menu above.</Empty>;
    else if (choosingDomain) {
        const available = domains.filter(domain => navigation.section === 'go-live' ? !domain.live : !spec || supportsDomain(spec, domain));
        content = !inventory ? loadError ? <Empty>The domain inventory could not be loaded. Use Refresh all to retry.</Empty> : <Busy>Loading registered domains…</Busy> : available.length ?
            <MenuCards items={available.map(domain => ({id: domain.domain, title: domain.domain, detail: `${domain.kind || domain.type} · ${domain.endpoints.length} endpoints · ${domain.settings?.ACCESS_MODE || 'access not reported'}`, badge: domain.live ? 'Live' : 'Staged', tone: domain.live ? 'success' : 'info'}))} onSelect={chooseDomain}/> : <Empty>{navigation.section === 'go-live' ? 'No staged domains are waiting to go live.' : 'No matching domains are registered. Choose Deploy a new domain from Manage to begin.'}</Empty>;
    } else if (!navigation.group) {
        content = <MenuCards items={groups.map(group => ({id: group.title, title: group.title, detail: group.operations.map(item => item.title).join(' · ')}))} onSelect={item => {
            const group = groups.find(group => group.title === item.id);
            navigate({...navigation, group: item.id, operation: group.operations.length === 1 ? operationId(group.operations[0]) : '', endpoint: undefined});
        }}/>;
    } else if (!spec) {
        content = <MenuCards items={(selectedGroup?.operations || []).map(item => ({id: operationId(item), title: item.title, detail: item.description, badge: item.mutates === false ? 'View' : undefined}))} onSelect={chooseOperation}/>;
    } else if (choosingEndpoint) {
        const field = fields.find(item => item.name === 'endpoint');
        const items = (selectedDomain?.endpoints || []).map(endpoint => ({id: endpoint.label, title: endpoint.label === 'root' ? 'Domain root' : `/${endpoint.label}/`, detail: endpoint.repository || `${endpoint.kind} endpoint`}));
        if (!field.required) items.unshift({id: '', title: endpointScopeLabel(spec), detail: 'Use the domain scope for this operation'});
        content = items.length ? <MenuCards items={items} onSelect={item => navigate({...navigation, endpoint: item.id})}/> : <Empty>No endpoints are registered for this domain. Add an endpoint from Endpoints and repositories.</Empty>;
    } else {
        content = <form className="management-form" onSubmit={submit}>
            {spec.description && <p className="text-secondary">{spec.description}</p>}
            {(navigation.domain || navigation.endpoint !== undefined) && <div className="management-context"><strong>{navigation.domain}</strong>{navigation.endpoint !== undefined && <span> · {navigation.endpoint ? navigation.endpoint === 'root' ? 'Domain root' : `/${navigation.endpoint}/` : endpointScopeLabel(spec)}</span>}</div>}
            <div className="filter-grid">{visibleFields.map(field => <OperationField key={`${navigation.operation}-${navigation.domain}-${navigation.endpoint}-${field.name}`} field={field.name === 'domain' && operationId(spec) === 'pages.upload_icon' ? {...field, scopeLabel: 'System icons'} : field} values={values} setValues={setValues} domains={domains} spec={spec} selectedDomain={selectedDomain} currentSettings={operationId(spec) === 'runtime.set' ? selectedEndpoint?.endpoint_settings : undefined} onError={onError}/>)}</div>
            {!!selectedEndpoint && operationId(spec) === 'runtime.set' && <details className="current-settings"><summary>Current endpoint settings</summary><DataTable rows={Object.entries(selectedEndpoint.endpoint_settings || {}).map(([key, value]) => ({key, value}))} columns={[{key: 'key', label: 'Setting'}, {key: 'value', label: 'Current value'}]}/></details>}
            <button className="btn btn-primary" disabled={paused || runtimeUnavailable}>Review operation</button>
        </form>;
    }
    const allJobs = rows(jobs, 'jobs');
    const active = allJobs.filter(job => activeStatuses.has(job.status));
    return <>
        {management?.refresh?.pending && <div className={`alert ${management.refresh.state === 'failed' ? 'alert-warning' : 'alert-info'}`} role="status"><strong>{management.refresh.state === 'failed' ? 'Management service update needs attention' : 'Management services are updating'}</strong><div>{management.refresh.state === 'failed' ? management.refresh.last_error || 'The service refresh could not be scheduled. Management remains available; retry the update or inspect the service from the CLI.' : 'Accepted jobs will finish before management restarts. Existing results and issued credentials remain available.'}</div></div>}
        <Panel title={spec?.title || navigation.group || (choosingDomain ? 'Choose a domain' : section?.title) || 'Server management'} detail="Follow the CLI menu flow. Started jobs continue when this page closes.">
            <nav aria-label="Management navigation" className="management-breadcrumb">{crumbs.map((crumb, index) => <React.Fragment key={`${index}-${crumb.label}`}>{index > 0 && <span aria-hidden="true">/</span>}{crumb.action && index < crumbs.length - 1 ? <button type="button" className="table-link" onClick={crumb.action}>{crumb.label}</button> : <span aria-current="page">{crumb.label}</span>}</React.Fragment>)}</nav>
            <ErrorNotice error={loadError}/>{content}
        </Panel>
        {!!active.length && <div className="alert alert-info" role="status">{active.length} active operation{active.length === 1 ? '' : 's'}. {active.some(job => job.status === 'waiting') ? 'An operation is waiting for the current CLI or management operation to finish; it will continue automatically.' : 'Select an operation below for live progress.'}</div>}
        <Panel title="Operation history" detail="Select a job to view live progress and output">{jobs ? <DataTable rows={allJobs} onSelect={async row => {
            try {onDetail('Operation details', await api(`jobs/${encodeURIComponent(row.id)}`));} catch (error) {onError(error);}
        }} columns={[
            {key: 'id', label: 'Job'}, {key: 'operation', label: 'Operation', render: row => operations.find(item => operationId(item) === row.operation)?.title || row.operation},
            {key: 'status', label: 'State', render: row => <Badge tone={['failed', 'interrupted'].includes(row.status) ? 'warning' : row.status === 'succeeded' ? 'success' : 'info'}>{row.status}</Badge>},
            {key: 'created', label: 'Submitted', render: row => date(row.created_at ?? row.created)},
            {key: 'started', label: 'Started', render: row => date(row.started_at ?? row.started)},
            {key: 'finished', label: 'Finished', render: row => date(row.finished_at ?? row.finished)},
        ]}/> : <Busy/>}</Panel>
    </>;
}
