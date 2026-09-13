import {test} from 'node:test';
import assert from 'node:assert/strict';
import {fetchRequest,blocked} from './fetch.mjs';
test('broker blocks private networks and mapped IPv6',()=>{
 for(const [ip,family] of [['127.0.0.1','ipv4'],['10.1.2.3','ipv4'],['169.254.169.254','ipv4'],['::1','ipv6'],['::ffff:127.0.0.1','ipv6'],['fe80::1','ipv6']])assert.ok(blocked.check(ip,family));
 assert.ok(!blocked.check('1.1.1.1','ipv4'));
});
test('broker rejects unapproved destinations, credentials and automatic POST',async()=>{
 for(const req of [
  {url:'https://example.com',method:'GET',allowedHosts:[]},
  {url:'file:///etc/passwd',method:'GET',allowedHosts:['']},
  {url:'https://user:pass@example.com',method:'GET',allowedHosts:['example.com']},
  {url:'https://example.com',method:'POST',allowedHosts:['example.com'],manual:false},
  {url:'http://127.0.0.1',method:'GET',allowedHosts:['127.0.0.1']}
 ]) await assert.rejects(fetchRequest(req));
});
