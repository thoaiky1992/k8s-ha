resource "helm_release" "cert_manager" {
  name = "cert-manager"

  chart            = "oci://quay.io/jetstack/charts/cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = "v1.21.2"
  wait             = true
  timeout          = 600

  set = [
    {
      name  = "crds.enabled"
      value = "true"
    }
  ]
}
