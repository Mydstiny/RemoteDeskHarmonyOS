/* Executes the production NAPI entry functions against a deterministic NAPI port.
 * This checks argument/return/exception behavior, not a device NAPI runtime.
 */
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process');
const root=path.resolve(__dirname,'../..');
const source=fs.readFileSync(path.join(root,'entry/src/main/cpp/extensions/extension_loader_napi.cpp'),'utf8');
const names=['ReadStrictNapiInt32Value','ReadStrictNapiInt64Value','ReadExactNapiCallbackArgs',
 'ReadClipboardAuthorityIdentity','NapiClaimSessionClipboardAuthority','SessionClipboardAuthorityTokenOperation',
 'NapiOwnsSessionClipboardAuthority','NapiRevokeSessionClipboardAuthority','NapiWithSessionClipboardAuthority'];
const extract=name=>{const start=source.search(new RegExp('^(?:static )?(?:bool|napi_value) '+name+'\\(','m'));
 if(start<0)throw Error('Missing production function '+name);const end=source.indexOf('\n}',start);if(end<0)throw Error('Unbounded function '+name);return source.slice(start,end+2);};
const directory=fs.mkdtempSync(path.join(os.tmpdir(),'clipboard-napi-test-'));
const fixture=String.raw`
#include "extensions/session_clipboard_authority.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <functional>
#include <limits>
#include <memory>
#include <vector>
enum napi_valuetype { napi_undefined, napi_boolean, napi_number, napi_function, napi_object, napi_string };
enum napi_status { napi_ok, napi_invalid_arg, napi_pending_exception };
struct Value;
using napi_value=Value*;
struct Env { std::vector<napi_value> args; bool exception=false; int cleared=0; };
using napi_env=Env*; using napi_callback_info=Env*;
struct Value { napi_valuetype type=napi_undefined; double number=0; bool boolean=false; std::function<napi_status(napi_value*)> callback; };
std::vector<std::unique_ptr<Value>> arena;
napi_value make(napi_valuetype type) { arena.push_back(std::make_unique<Value>());arena.back()->type=type;return arena.back().get(); }
napi_value number(double value) { auto result=make(napi_number);result->number=value;return result; }
napi_value boolean(bool value) { auto result=make(napi_boolean);result->boolean=value;return result; }
napi_value function(std::function<napi_status(napi_value*)> callback) { auto result=make(napi_function);result->callback=callback;return result; }
napi_status napi_get_cb_info(napi_env,napi_callback_info info,size_t* argc,napi_value* args,void*,void*) {
 *argc=std::min(*argc,info->args.size());for(size_t i=0;i<*argc;i++)args[i]=info->args[i];return napi_ok;
}
napi_status napi_typeof(napi_env,napi_value value,napi_valuetype* out) { if(!value)return napi_invalid_arg;*out=value->type;return napi_ok; }
napi_status napi_get_value_double(napi_env,napi_value value,double* out) { if(!value||value->type!=napi_number)return napi_invalid_arg;*out=value->number;return napi_ok; }
napi_status napi_get_value_bool(napi_env,napi_value value,bool* out) { if(!value||value->type!=napi_boolean)return napi_invalid_arg;*out=value->boolean;return napi_ok; }
napi_status napi_get_boolean(napi_env,bool value,napi_value* out) { *out=boolean(value);return napi_ok; }
napi_status napi_create_int64(napi_env,int64_t value,napi_value* out) { *out=number(static_cast<double>(value));return napi_ok; }
napi_status napi_get_undefined(napi_env,napi_value* out) { *out=make(napi_undefined);return napi_ok; }
napi_status napi_call_function(napi_env,napi_value,napi_value callback,size_t argc,const napi_value*,napi_value* out) {
 assert(argc==0);return callback->callback(out);
}
napi_status napi_is_exception_pending(napi_env env,bool* out) { *out=env->exception;return napi_ok; }
napi_status napi_get_and_clear_last_exception(napi_env env,napi_value* out) { *out=make(napi_object);env->exception=false;env->cleared++;return napi_ok; }
SessionClipboardAuthority g_sessionClipboardAuthority;
bool living=true;
static bool IsClipboardAuthoritySessionAlive(int32_t sid,uint64_t generation) { return living&&(sid==7||sid==8)&&generation==11; }
`;
const checks=String.raw`
int main() {
 Env env;
 env.args={number(7),number(11)};
 auto token=NapiClaimSessionClipboardAuthority(&env,&env);assert(token->number>0);
 auto id=token->number;
 env.args={number(8),number(11)};assert(NapiClaimSessionClipboardAuthority(&env,&env)->number==0);
 env.args={number(8),number(11),number(1)};assert(NapiClaimSessionClipboardAuthority(&env,&env)->number==0);
 env.args={number(7),number(11),boolean(true),boolean(true)};assert(NapiClaimSessionClipboardAuthority(&env,&env)->number==0);
 int calls=0;
 auto success=function([&](napi_value* out){calls++;assert(g_sessionClipboardAuthority.owns(7,11,static_cast<uint64_t>(id),IsClipboardAuthoritySessionAlive));*out=boolean(true);return napi_ok;});
 env.args={number(7),number(11),token,success};assert(NapiWithSessionClipboardAuthority(&env,&env)->boolean);assert(calls==1);
 // Undefined, object (including Promise) and truthy numeric results are never accepted.
 for(auto kind:{napi_undefined,napi_object,napi_number}) {
   auto invalidReturn=function([&](napi_value* out){*out=make(kind);return napi_ok;});
   env.args={number(7),number(11),token,invalidReturn};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);
 }
 auto failed=function([&](napi_value* out){*out=boolean(false);return napi_ok;});
 env.args={number(7),number(11),token,failed};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);
 auto throwing=function([&](napi_value*){env.exception=true;return napi_pending_exception;});
 env.args={number(7),number(11),token,throwing};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);assert(!env.exception&&env.cleared==1);
 for(auto bad:{number(0),number(-1),number(1.5),number(std::numeric_limits<double>::quiet_NaN()),number(9007199254740992.0),make(napi_string)}) {
   env.args={number(7),number(11),bad,success};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);
 }
 env.args={number(7),number(11),token,success,make(napi_undefined)};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);
 env.args={number(7),number(11),token};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);
 env.args={number(7),number(11),token,make(napi_object)};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);
 assert(calls==1);
 env.args={number(8),number(11),boolean(true)};auto next=NapiClaimSessionClipboardAuthority(&env,&env);assert(next->number>id);
 env.args={number(7),number(11),token,success};assert(!NapiWithSessionClipboardAuthority(&env,&env)->boolean);assert(calls==1);
 env.args={number(7),number(11),token};assert(!NapiRevokeSessionClipboardAuthority(&env,&env)->boolean);
 env.args={number(8),number(11),next};assert(NapiOwnsSessionClipboardAuthority(&env,&env)->boolean);
 living=false;assert(!NapiOwnsSessionClipboardAuthority(&env,&env)->boolean);
 living=true;assert(!NapiOwnsSessionClipboardAuthority(&env,&env)->boolean);
 std::puts("PASS 8 production NAPI authority groups: claim, nested owns, strict bool, exception, invalid token, exact arity, stale owner, dead lifecycle");
}
`;
const input=path.join(directory,'authority.cpp'),binary=path.join(directory,'authority');
fs.writeFileSync(input,fixture+'\n'+names.map(extract).join('\n\n')+'\n'+checks);
for(const [command,args] of [['clang++',['-std=c++17','-pthread','-Wall','-Wextra','-Werror','-I'+path.join(root,'entry/src/main/cpp'),input,'-o',binary]],[binary,[]]]) {
 const result=cp.spawnSync(command,args,{encoding:'utf8'});process.stdout.write(result.stdout||'');process.stderr.write(result.stderr||'');
 if(result.status!==0)throw Error('Host test failed; retained fixture '+directory);
}
fs.rmSync(directory,{recursive:true,force:true});
