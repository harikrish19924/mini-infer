# operator

Kubebuilder project for the `InferenceService` CRD, its controller and the autoscaler.
It is a separate Go module, scaffolded in phase 4:

```sh
cd operator
kubebuilder init --domain tinyinfer.dev --repo github.com/harikrish19924/mini-infer/operator
kubebuilder create api --group serving --version v1alpha1 --kind InferenceService
```
