-- cartograph.k8sapi — the derivation rules over a SYNTHETIC API tree (a core and an apps package, written to a temp dir;
-- the real one is a kubernetes checkout, which tests never read — tools/k8sapi.lua --check is its drift gate).
local K = require 'cartograph.k8sapi'

local function ready() return pcall(vim.treesitter.get_string_parser, '', 'go') end
local function tree(files)
    local root = vim.fn.tempname()
    for rel, text in pairs(files) do
        vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. rel, ':h'), 'p')
        local fd = assert(io.open(root .. '/' .. rel, 'w')); fd:write(text); fd:close()
    end
    return root
end
local CORE_REG = [[
package v1
const GroupName = ""
func addKnownTypes(scheme *runtime.Scheme) error {
	scheme.AddKnownTypes(SchemeGroupVersion, &Pod{}, &PodList{}, &ConfigMap{}, &Secret{}, &Service{}, &StorageClass{}, &PersistentVolume{}, &PersistentVolumeClaim{})
	return nil
}
]]
local CORE_TYPES = [[
package v1
type LocalObjectReference struct {
	Name string `json:"name,omitempty"`
}
type ConfigMapEnvSource struct {
	LocalObjectReference `json:",inline"`
	Optional *bool `json:"optional,omitempty"`
}
type ObjectReference struct {
	Kind string `json:"kind,omitempty"`
	Name string `json:"name,omitempty"`
}
type EnvFromSource struct {
	ConfigMapRef *ConfigMapEnvSource `json:"configMapRef,omitempty"`
}
type ContainerPort struct {
	// Name for the port that can be referred to by services.
	Name string `json:"name,omitempty"`
}
type EnvVarSource struct {
	FileKeyRef *FileKeySelector `json:"fileKeyRef,omitempty"`
}
type EnvVar struct {
	ValueFrom *EnvVarSource `json:"valueFrom,omitempty"`
}
type GRPCAction struct {
	Port int32 `json:"port"`
}
type HTTPGetAction struct {
	Path string `json:"path,omitempty"`
}
type ProbeHandler struct {
	HTTPGet *HTTPGetAction `json:"httpGet,omitempty"`
	GRPC *GRPCAction `json:"grpc,omitempty"`
}
type Probe struct {
	ProbeHandler `json:",inline"`
}
type Container struct {
	ReadinessProbe *Probe `json:"readinessProbe,omitempty"`
	Env []EnvVar `json:"env,omitempty"`
	EnvFrom []EnvFromSource `json:"envFrom,omitempty"`
	Ports []ContainerPort `json:"ports,omitempty"`
}
type PodSpec struct {
	Containers []Container `json:"containers"`
	ImagePullSecrets []LocalObjectReference `json:"imagePullSecrets,omitempty"`
	SchedulerName string `json:"schedulerName,omitempty"`
}
type PodTemplateSpec struct {
	Spec PodSpec `json:"spec,omitempty"`
}
type Pod struct {
	Spec PodSpec `json:"spec,omitempty"`
}
type ServiceSpec struct {
	// Route service traffic to pods with label keys and values matching this selector.
	Selector map[string]string `json:"selector,omitempty"`
}
type Service struct {
	Spec ServiceSpec `json:"spec,omitempty"`
}
type PersistentVolumeClaimSpec struct {
	// a label query over volumes to consider for binding.
	Selector *metav1.LabelSelector `json:"selector,omitempty"`
	// volumeName is the binding reference to the PersistentVolume backing this claim.
	VolumeName string `json:"volumeName,omitempty"`
	StorageClassName *string `json:"storageClassName,omitempty"`
	DataSourceRef *ObjectReference `json:"dataSourceRef,omitempty"`
	// (the roleRef shape: a field named after a kind whose type carries its OWN kind)
	SecretRef *ObjectReference `json:"secretRef,omitempty"`
}
type PersistentVolumeClaim struct {
	Spec PersistentVolumeClaimSpec `json:"spec,omitempty"`
}
type FileKeySelector struct {
	// The name of the volume mount containing the env file.
	VolumeName string `json:"volumeName"`
}
type ConfigMap struct {
	Data map[string]string `json:"data,omitempty"`
}
type Secret struct {
	Data map[string][]byte `json:"data,omitempty"`
}
// +genclient
// +genclient:nonNamespaced
type PersistentVolume struct {
	Spec string `json:"spec,omitempty"`
}
// +genclient:nonNamespaced
type StorageClass struct {
	Provisioner string `json:"provisioner"`
}
]]
local APPS_REG = [[
package v1
const GroupName = "apps"
func addKnownTypes(scheme *runtime.Scheme) error {
	scheme.AddKnownTypes(SchemeGroupVersion, &Deployment{}, &DeploymentList{})
	return nil
}
]]
local APPS_TYPES = [[
package v1
import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)
type DeploymentSpec struct {
	// Label selector for pods.
	Selector *metav1.LabelSelector `json:"selector"`
	Template corev1.PodTemplateSpec `json:"template"`
}
type Deployment struct {
	Spec DeploymentSpec `json:"spec,omitempty"`
}
]]
local function derive()
    local root = tree({ ['core/v1/register.go'] = CORE_REG, ['core/v1/types.go'] = CORE_TYPES, ['apps/v1/register.go'] = APPS_REG, ['apps/v1/types.go'] = APPS_TYPES })
    local S = assert(K.read(root))
    local D = K.derive(S)
    local refs = {}
    for _, r in ipairs(D.refs) do refs[r.kind .. ' ' .. r.path] = (r.target or '<kind>') .. ' ' .. r.how end
    return S, D, refs
end

test('k8sapi: KINDS from register.go (a List is not a kind), groups from GroupName, scope from +genclient:nonNamespaced', function ()
    if not ready() then skip 'no go parser' end
    local S = derive()
    eq('apps', S.kinds.Deployment.group)
    eq('', S.kinds.Pod.group, 'the core group is the empty one')
    eq(nil, S.kinds.DeploymentList, 'a List type is registered but no manifest declares one')
    eq(true, S.cluster.StorageClass and S.cluster.PersistentVolume, 'the nonNamespaced marker above the type')
    eq(nil, S.cluster.Service)
end)

test('k8sapi: the POD TEMPLATE path through an IMPORTED type (corev1.PodTemplateSpec), and a Pod\'s own spec', function ()
    if not ready() then skip 'no go parser' end
    local _, D = derive()
    eq({ 'spec.template.spec' }, D.pod.Deployment)
    eq({ 'spec' }, D.pod.Pod)
end)

test('k8sapi: REFERENCES and their targets read from the source\'s own words', function ()
    if not ready() then skip 'no go parser' end
    local _, _, refs = derive()
    eq('ConfigMap ref', refs['Deployment spec.template.spec.containers[].envFrom[].configMapRef'], 'the json stem, through an embedding struct')
    eq('Secret ref', refs['Deployment spec.template.spec.imagePullSecrets[]'], 'a compound stem\'s camel tail: imagePullSecret -> Secret')
    eq('<kind> ref', refs['PersistentVolumeClaim spec.dataSourceRef'], 'a reference carrying its own kind is resolved at run time')
    eq('<kind> ref', refs['PersistentVolumeClaim spec.secretRef'], 'its own kind WINS over a field name that names a kind (roleRef: Role or ClusterRole)')
    eq('PersistentVolume name', refs['PersistentVolumeClaim spec.volumeName'], 'a suffix match kept: the doc names the kind in full')
    eq('StorageClass name', refs['PersistentVolumeClaim spec.storageClassName'], 'an exact stem needs no doc')
    eq('Pod selector', refs['Deployment spec.selector'], 'a selector\'s target from its doc: "Label selector for pods"')
    eq('Pod selector', refs['Service spec.selector{}'], 'the declaring kind is skipped: "service traffic to pods"')
    eq('PersistentVolume selector', refs['PersistentVolumeClaim spec.selector'], '"a label query over volumes"')
    eq(nil, refs['Deployment spec.template.spec.schedulerName'], 'a <x>Name whose x is no kind is no edge')
    eq(nil, refs['Deployment spec.template.spec.containers[].ports[].name'], 'a port "referred to BY services" is not a reference it makes')
    eq(nil, refs['Deployment spec.template.spec.containers[].env[].valueFrom.fileKeyRef.volumeName'],
        'a stem that only ENDS a kind (volume) whose doc never names the kind in full is no edge')
end)

test('k8sapi: PROBES — every field typed Probe — and the handler\'s gRPC / HTTP fields by their TYPE (CART-0834)', function ()
    if not ready() then skip 'no go parser' end
    local _, D = derive()
    eq({ 'spec.template.spec.containers[].readinessProbe' }, D.probes.Deployment)
    eq({ grpc = 'grpc', http = 'httpGet' }, D.probe_handler)
end)

test('k8sapi: the table serializes DETERMINISTICALLY and round-trips', function ()
    if not ready() then skip 'no go parser' end
    local S, D = derive()
    local a = K.serialize(K.table(S, D, 'test'))
    local b = K.serialize(K.table(S, D, 'test'))
    eq(a, b, 'byte-identical: the drift check compares text')
    local t = assert(loadstring(a))()
    eq('spec.template.spec', t.pod.Deployment)
    eq(true, t.cluster.StorageClass)
    ok(#t.refs > 5)
end)

test('k8sapi: the SHIPPED table loads and carries the real API\'s answers', function ()
    local t = K.load()
    ok(t ~= nil, 'lua/cartograph/k8sapi_table.lua is generated and shipped')
    eq('spec.jobTemplate.spec.template.spec', t.pod.CronJob)
    eq(true, t.cluster.StorageClass and t.cluster.Node and t.cluster.Namespace)
    local found = false
    for _, r in ipairs(t.refs) do if r[1] == 'Ingress' and r[2]:find('backend%.service%.name$') and r[3] == 'Service' then found = true end end
    ok(found, 'Ingress -> Service by the backend\'s referenced service name')
end)
