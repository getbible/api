import test from 'node:test';
import assert from 'node:assert/strict';
import {defaultTargets, selectedTargets, upgradeSubmission, capacitySetting} from '../src/upgrades.js';
const plan = {plan_id:'a'.repeat(64), targets:[
    {id:'management',status:'pending',eligible:true,outcome:'failed'},
    {id:'runtime/query.example.test/v2',status:'pending',eligible:true,outcome:'untracked'},
    {id:'runtime/query.example.test/v3',status:'current',eligible:false,outcome:'applied'},
    {id:'mcp/mcp.example.test',status:'blocked',eligible:false,outcome:'failed'},
    {id:'static/api.example.test',status:'updating',eligible:false,outcome:'updating'},
]};
test('only changed selectable targets are preselected', () => assert.deepEqual(defaultTargets(plan), ['management','runtime/query.example.test/v2']));
test('empty selection never expands to all targets', () => assert.deepEqual(upgradeSubmission(plan, []).targets, []));
test('selection does not deploy siblings or blocked work, even with force', () => {
    assert.deepEqual(selectedTargets(plan,plan.targets.map(r=>r.id),{force:true}),plan.targets.slice(0,3).map(r=>r.id));
    assert.deepEqual(upgradeSubmission(plan,['runtime/query.example.test/v2']).targets,['runtime/query.example.test/v2']);
});
test('retry is limited to failed/interrupted choices; current targets need force',()=>{
    assert.deepEqual(selectedTargets(plan,plan.targets.map(r=>r.id),{retry:true}),['management']);
    assert.deepEqual(selectedTargets(plan,['runtime/query.example.test/v3']),[]);
});
test('submission carries reviewed plan and rejects missing or invalid identity',()=>{
    assert.equal(upgradeSubmission(plan,['management']).plan_id,plan.plan_id);
    assert.throws(()=>upgradeSubmission(null,[]));
    assert.throws(()=>upgradeSubmission({...plan,plan_id:'--all'},[]));
});
test('sizing advice cannot change stale, environment-owned or non-application limits',()=>{
    const row={setting:'TELEMETRY_SPOOL_MAX_GIB',recommendation:{status:'suggested',value:3},configuration:{owner:'saved',editable:true}};
    assert.deepEqual(capacitySetting(row),{key:row.setting,value:'3'});
    for(const value of [capacitySetting(row,true),capacitySetting({...row,configuration:{owner:'environment',editable:false}}),
        capacitySetting({...row,setting:'GETBIBLE_MEMORY_LIMIT'}),capacitySetting({...row,recommendation:{status:'investigate_collection',value:null}})])assert.equal(value,null);
});
