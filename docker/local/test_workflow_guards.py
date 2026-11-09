"""Pure unit tests: never invokes Docker or connects to a database."""
import copy, importlib.machinery, importlib.util, json, pathlib, tempfile, unittest
from unittest import mock
ROOT=pathlib.Path(__file__).resolve().parents[2]
loader=importlib.machinery.SourceFileLoader('qflocal',str(ROOT/'bin/local'))
spec=importlib.util.spec_from_loader(loader.name,loader); module=importlib.util.module_from_spec(spec); loader.exec_module(module)
class Guards(unittest.TestCase):
    def setUp(self):
        module.MODE='check'
        self.cfg={'services':{'web':{'networks':{'isolated':{}},'volumes':[{'type':'bind','source':str(ROOT/'docker/local'),'target':'/local','read_only':True}],'environment':{}},'caddy':{'networks':{'isolated':{},'ingress':{}},'ports':[{'host_ip':'127.0.0.1'}]}},'networks':{'isolated':{'internal':True},'ingress':{}}}
        module.compose=lambda *args,**kwargs:json.dumps(self.cfg)
    def test_accepts_local_isolated_config(self): module.configuration_guard()
    def test_refuses_public_port(self):
        self.cfg['services']['caddy']['ports'][0]['host_ip']='0.0.0.0'
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_refuses_whole_repo_bind(self):
        self.cfg['services']['web']['volumes'][0]['source']=str(ROOT)
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_refuses_config_root_bind(self):
        self.cfg['services']['web']['volumes'][0]['source']=str(ROOT/'config')
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_refuses_writable_bind(self):
        self.cfg['services']['web']['volumes'][0]['read_only']=False
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_refuses_api_credentials(self):
        self.cfg['services']['web']['environment']['OPENAI_API_KEY']='not-real'
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_refuses_external_app_network(self):
        self.cfg['services']['web']['networks']['ingress']={}
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_refuses_noninternal_network(self):
        self.cfg['networks']['isolated']['internal']=False
        self.assertRaises(RuntimeError,module.configuration_guard)
    def test_detects_missing_initializer_binds(self):
        module.MODE='dev'; self.assertRaises(RuntimeError,module.configuration_guard)
class RuntimeGuards(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.cfg={'services':{'db':{'image':'local-db'}}}
        self.container={'Config':{'Labels':{'com.docker.compose.project':'unit-project','com.docker.compose.service':'db'},'Env':[]},'State':{'Running':False},'Image':'sha256:db','NetworkSettings':{'Networks':{}},'HostConfig':{},'Mounts':[]}
        for key,value in {'PROJECT':'unit-project','MODE':'test','DOCKER':['docker'],'EVIDENCE':pathlib.Path(self.temp.name)}.items():
            patch=mock.patch.object(module,key,value,create=True); patch.start(); self.addCleanup(patch.stop)
        patch=mock.patch.object(module,'configuration_guard',return_value=self.cfg); patch.start(); self.addCleanup(patch.stop)
        patch=mock.patch.object(module,'inspect',side_effect=lambda kind,name:self.container if kind=='container' else {'Id':'sha256:db'}); patch.start(); self.addCleanup(patch.stop)
    def test_required_services_rejects_zero_containers(self):
        with mock.patch.object(module,'run',return_value=''):
            with self.assertRaisesRegex(RuntimeError,'Required services not running: db'): module.runtime_guard(('db',))
        self.assertFalse((module.EVIDENCE/'isolation.json').exists())
    def test_required_services_rejects_stopped_container(self):
        with mock.patch.object(module,'run',return_value='stopped-db'):
            with self.assertRaisesRegex(RuntimeError,'Required services not running: db'): module.runtime_guard(('db',))
    def test_required_services_accepts_running_expected_image(self):
        self.container['State']['Running']=True
        with mock.patch.object(module,'run',return_value='running-db'):
            self.assertEqual(module.runtime_guard(('db',))['running_services'],['db'])
    def test_verify_requests_all_check_services(self):
        module.MODE='check'
        with mock.patch.object(module,'ACTION','verify',create=True), mock.patch.object(module,'marker_guard'), mock.patch.object(module,'image_guard'), mock.patch.object(module,'runtime_guard',return_value={}) as guard:
            module.main(); guard.assert_called_once_with(('db','web','caddy'))

class ImageGuards(unittest.TestCase):
    def setUp(self):
        self.env={'QF_LOCK_SHA':module.digest(ROOT/'Gemfile.lock'),'QF_SOURCE_SHA':'current-source','QF_DEPS_SHA':'current-deps'}
        self.image={'Id':'sha256:test-image','Config':{'Labels':{'io.quickflow.local.mode':'check','io.quickflow.local.lock':self.env['QF_LOCK_SHA'],'io.quickflow.local.source':'current-source','io.quickflow.local.dependencies':'current-deps'}}}
        self.actual='\n'.join([(ROOT/'.ruby-version').read_text().strip(),self.env['QF_LOCK_SHA'],module.digest(ROOT/'Gemfile')])
        for key,value in {'MODE':'check','ENV':self.env,'DOCKER':['docker']}.items():
            patch=mock.patch.object(module,key,value,create=True); patch.start(); self.addCleanup(patch.stop)
        patch=mock.patch.object(module,'inspect',return_value=self.image); patch.start(); self.addCleanup(patch.stop)
    def test_accepts_matching_actual_image(self):
        with mock.patch.object(module,'run',return_value=self.actual): self.assertEqual(module.image_guard('unit-image'),'sha256:test-image')
    def test_rejects_stale_source_before_run(self):
        self.image['Config']['Labels']['io.quickflow.local.source']='stale-source'
        with mock.patch.object(module,'run') as run:
            with self.assertRaisesRegex(RuntimeError,'source changed'): module.image_guard('unit-image')
            run.assert_not_called()
    def test_rejects_actual_lock_even_with_matching_label(self):
        with mock.patch.object(module,'run',return_value=self.actual.replace(self.env['QF_LOCK_SHA'],'wrong-lock')):
            with self.assertRaisesRegex(RuntimeError,'Actual image Ruby/Gemfile/lock'): module.image_guard('unit-image')
    def test_rejects_stale_dev_dependency_before_run(self):
        module.MODE='dev'; labels=self.image['Config']['Labels']; labels['io.quickflow.local.mode']='dev'; labels['io.quickflow.local.dependencies']='stale-deps'
        with mock.patch.object(module,'run') as run:
            with self.assertRaisesRegex(RuntimeError,'Development dependencies changed'): module.image_guard('unit-image')
            run.assert_not_called()

class ReadinessGuards(unittest.TestCase):
    def test_redirects_are_rejected_without_network(self):
        handler=module.NoReadinessRedirect()
        request=module.urllib.request.Request('http://localhost:18080/up')
        for target in ('http://localhost:18080/login','https://example.com/up','http://169.254.169.254/'):
            with self.subTest(target=target), mock.patch.object(module.urllib.request,'urlopen',side_effect=AssertionError('Network forbidden')):
                with self.assertRaisesRegex(RuntimeError,'refusing to follow'):
                    handler.redirect_request(request,None,302,'Found',{},target)

class TestActions(unittest.TestCase):
    def test_core_and_full_share_guards_but_not_exclusions_or_artifacts(self):
        for action in ('test','test-core'):
            with self.subTest(action=action), mock.patch.multiple(module,MODE='test',ACTION=action,PROJECT='unit-project',DOCKER=['docker'],EVIDENCE=pathlib.Path('/unit-evidence'),create=True), mock.patch.object(module,'configuration_guard'), mock.patch.object(module,'marker_guard') as marker, mock.patch.object(module,'image_guard',return_value='sha256:test') as image, mock.patch.object(module,'runtime_guard') as runtime, mock.patch.object(module,'compose',return_value=0) as compose, mock.patch.object(module,'run') as run:
                module.main()
                marker.assert_called_once(); image.assert_called_once(); runtime.assert_called_once_with(('db',))
                args=compose.call_args.args
                self.assertEqual('--exclude-pattern' in args,action=='test-core')
                artifact='rspec-core' if action=='test-core' else 'rspec'
                self.assertEqual(compose.call_args.kwargs['log'],pathlib.Path('/unit-evidence')/(artifact+'.log'))
                self.assertEqual(run.call_args.args[0][-1],'/unit-evidence/'+artifact+'.json')

if __name__=='__main__': unittest.main()
