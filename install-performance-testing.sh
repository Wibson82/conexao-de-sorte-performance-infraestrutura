#!/usr/bin/env bash

# ============================================================================
# 📊 PERFORMANCE TESTING INSTALLER - CONEXÃO DE SORTE PERFORMANCE INFRASTRUCTURE
# ============================================================================
# Script para instalação e configuração completa de testes de performance
# com K6 para todos os microsserviços conexao-de-sorte-backend-{nome}
# ============================================================================

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configurações
K6_OPERATOR_VERSION="v0.0.14"
K6_NAMESPACE="k6-system"
TARGET_NAMESPACE="default"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Função para log colorido
log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

log_header() {
    echo -e "${PURPLE}🎯 $1${NC}"
}

log_step() {
    echo -e "${CYAN}🔄 $1${NC}"
}

# Função para verificar pré-requisitos
check_prerequisites() {
    log_header "Verificando pré-requisitos para Performance Testing..."
    
    # Verificar kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl não encontrado. Instale kubectl primeiro."
        exit 1
    fi
    
    # Verificar conexão com cluster
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Não foi possível conectar ao cluster Kubernetes."
        exit 1
    fi
    
    # Verificar se os microsserviços estão rodando
    log_step "Verificando microsserviços alvo..."
    local services=("conexao-de-sorte-backend-autenticacao" "conexao-de-sorte-backend-financeiro" "conexao-de-sorte-backend-gateway")
    
    for service in "${services[@]}"; do
        if kubectl get deployment "$service" -n "$TARGET_NAMESPACE" &> /dev/null; then
            log_success "Serviço $service encontrado"
        else
            log_warning "Serviço $service não encontrado - testes podem falhar"
        fi
    done
    
    # Verificar se Prometheus está disponível
    if kubectl get deployment prometheus -n istio-system &> /dev/null; then
        log_success "Prometheus encontrado para coleta de métricas"
    else
        log_warning "Prometheus não encontrado - métricas limitadas"
    fi
    
    log_success "Pré-requisitos verificados"
}

# Função para instalar K6 Operator
install_k6_operator() {
    log_header "Instalando K6 Operator..."
    
    # Criar namespace
    log_step "Criando namespace $K6_NAMESPACE..."
    kubectl create namespace "$K6_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Instalar K6 Operator
    log_step "Instalando K6 Operator $K6_OPERATOR_VERSION..."
    kubectl apply -f "https://github.com/grafana/k6-operator/releases/download/$K6_OPERATOR_VERSION/bundle.yaml"
    
    # Aguardar operator
    log_step "Aguardando K6 Operator..."
    kubectl wait --for=condition=available --timeout=300s deployment/k6-operator-controller-manager -n k6-operator-system || true
    
    log_success "K6 Operator instalado com sucesso"
}

# Função para configurar testes de performance
configure_performance_tests() {
    log_header "Configurando testes de performance..."
    
    # Aplicar configurações
    log_step "Aplicando configurações de teste..."
    kubectl apply -f "$SCRIPT_DIR/k6-performance-tests.yaml"
    
    # Aguardar ConfigMaps
    log_step "Aguardando ConfigMaps serem criados..."
    kubectl wait --for=condition=complete --timeout=60s configmap/conexao-de-sorte-k6-scripts -n "$K6_NAMESPACE" || true
    
    log_success "Configurações de teste aplicadas"
}

# Função para criar testes individuais
create_individual_tests() {
    log_header "Criando arquivos de teste individuais..."
    
    # Criar diretório para testes individuais
    mkdir -p "$SCRIPT_DIR/individual-tests"
    
    # Teste para Autenticação
    cat > "$SCRIPT_DIR/individual-tests/k6-test-autenticacao.yaml" << 'EOF'
apiVersion: k6.io/v1alpha1
kind: K6
metadata:
  name: conexao-de-sorte-backend-autenticacao-test
  namespace: k6-system
spec:
  parallelism: 4
  script:
    configMap:
      name: conexao-de-sorte-k6-scripts
      file: autenticacao-load-test.js
  runner:
    image: grafana/k6:latest
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 200m
        memory: 256Mi
EOF

    # Teste para Gateway
    cat > "$SCRIPT_DIR/individual-tests/k6-test-gateway.yaml" << 'EOF'
apiVersion: k6.io/v1alpha1
kind: K6
metadata:
  name: conexao-de-sorte-backend-gateway-test
  namespace: k6-system
spec:
  parallelism: 6
  script:
    configMap:
      name: conexao-de-sorte-k6-scripts
      file: gateway-load-test.js
  runner:
    image: grafana/k6:latest
    resources:
      limits:
        cpu: 1000m
        memory: 1Gi
      requests:
        cpu: 300m
        memory: 512Mi
EOF

    # Teste para Financeiro
    cat > "$SCRIPT_DIR/individual-tests/k6-test-financeiro.yaml" << 'EOF'
apiVersion: k6.io/v1alpha1
kind: K6
metadata:
  name: conexao-de-sorte-backend-financeiro-test
  namespace: k6-system
spec:
  parallelism: 2
  script:
    configMap:
      name: conexao-de-sorte-k6-scripts
      file: financeiro-load-test.js
  runner:
    image: grafana/k6:latest
    resources:
      limits:
        cpu: 300m
        memory: 256Mi
      requests:
        cpu: 100m
        memory: 128Mi
EOF

    log_success "Arquivos de teste individuais criados em individual-tests/"
}

# Função para executar teste de validação
run_validation_test() {
    log_header "Executando teste de validação..."
    
    # Executar teste simples no Gateway
    log_step "Executando teste de validação no Gateway..."
    kubectl apply -f "$SCRIPT_DIR/individual-tests/k6-test-gateway.yaml"
    
    # Aguardar conclusão
    log_step "Aguardando conclusão do teste..."
    sleep 60
    
    # Verificar resultado
    local test_status=$(kubectl get k6 conexao-de-sorte-backend-gateway-test -n "$K6_NAMESPACE" -o jsonpath='{.status.stage}' 2>/dev/null || echo "")
    
    if [[ "$test_status" == "finished" ]]; then
        log_success "Teste de validação concluído com sucesso"
    elif [[ "$test_status" == "error" ]]; then
        log_warning "Teste de validação falhou - verifique logs"
    else
        log_warning "Teste ainda em execução ou status indeterminado: $test_status"
    fi
    
    # Limpar teste de validação
    kubectl delete k6 conexao-de-sorte-backend-gateway-test -n "$K6_NAMESPACE" --ignore-not-found=true
}

# Função para configurar monitoramento
configure_monitoring() {
    log_header "Configurando monitoramento de performance..."
    
    # Verificar se Prometheus está disponível
    if kubectl get deployment prometheus -n istio-system &> /dev/null; then
        log_step "Configurando integração com Prometheus..."
        
        # Aplicar ServiceMonitor para K6
        cat << EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: k6-performance-metrics
  namespace: $K6_NAMESPACE
  labels:
    app.kubernetes.io/name: k6
    app.kubernetes.io/part-of: conexao-de-sorte-performance
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: k6
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
EOF
        
        log_success "Monitoramento configurado com Prometheus"
    else
        log_warning "Prometheus não encontrado - monitoramento limitado"
    fi
}

# Função para mostrar informações pós-instalação
show_post_install_info() {
    log_header "Informações pós-instalação do Performance Testing"
    
    echo ""
    echo "📊 K6 Performance Testing instalado com sucesso!"
    echo ""
    echo "🔧 Comandos para executar testes:"
    echo "  • Teste Autenticação: kubectl apply -f individual-tests/k6-test-autenticacao.yaml"
    echo "  • Teste Gateway: kubectl apply -f individual-tests/k6-test-gateway.yaml"
    echo "  • Teste Financeiro: kubectl apply -f individual-tests/k6-test-financeiro.yaml"
    echo ""
    echo "📊 Monitoramento de testes:"
    echo "  • Listar testes: kubectl get k6 -n $K6_NAMESPACE"
    echo "  • Status do teste: kubectl describe k6 <test-name> -n $K6_NAMESPACE"
    echo "  • Logs do teste: kubectl logs -f job/<test-name> -n $K6_NAMESPACE"
    echo ""
    echo "⏰ Testes automatizados:"
    echo "  • CronJob configurado para execução diária às 2h"
    echo "  • Verificar: kubectl get cronjob -n $K6_NAMESPACE"
    echo ""
    echo "📈 Métricas disponíveis:"
    echo "  • http_req_duration: Tempo de resposta das requests"
    echo "  • http_req_failed: Taxa de falha das requests"
    echo "  • k6_test_duration: Duração total dos testes"
    echo ""
    echo "📋 Próximos passos:"
    echo "  1. Executar testes individuais para validação"
    echo "  2. Configurar alertas baseados nas métricas"
    echo "  3. Ajustar thresholds conforme necessário"
    echo "  4. Integrar com pipeline CI/CD"
    echo ""
    echo "⚠️ Importante:"
    echo "  • Testes de carga podem impactar performance"
    echo "  • Execute em horários de baixo tráfego"
    echo "  • Monitore recursos do cluster durante testes"
    echo ""
}

# Função principal
main() {
    case "${1:-install}" in
        "install")
            check_prerequisites
            install_k6_operator
            configure_performance_tests
            create_individual_tests
            configure_monitoring
            run_validation_test
            show_post_install_info
            ;;
        "test")
            local service="${2:-gateway}"
            log_info "Executando teste para $service..."
            kubectl apply -f "$SCRIPT_DIR/individual-tests/k6-test-$service.yaml"
            ;;
        "validate")
            run_validation_test
            ;;
        "uninstall")
            log_warning "Desinstalando K6 Performance Testing..."
            kubectl delete -f "$SCRIPT_DIR/k6-performance-tests.yaml" --ignore-not-found=true
            kubectl delete -f "https://github.com/grafana/k6-operator/releases/download/$K6_OPERATOR_VERSION/bundle.yaml" --ignore-not-found=true
            kubectl delete namespace "$K6_NAMESPACE" --ignore-not-found=true
            rm -rf "$SCRIPT_DIR/individual-tests"
            log_success "K6 Performance Testing desinstalado"
            ;;
        "help"|*)
            echo "📊 Performance Testing Installer"
            echo ""
            echo "Uso: $0 [COMANDO] [SERVIÇO]"
            echo ""
            echo "Comandos:"
            echo "  install              Instalar K6 Performance Testing completo (padrão)"
            echo "  test [SERVIÇO]       Executar teste para serviço específico"
            echo "  validate             Executar teste de validação"
            echo "  uninstall            Desinstalar K6 completamente"
            echo "  help                 Mostrar esta ajuda"
            echo ""
            echo "Serviços disponíveis:"
            echo "  • autenticacao       Teste de carga para autenticação"
            echo "  • gateway            Teste de carga para gateway"
            echo "  • financeiro         Teste conservador para financeiro"
            ;;
    esac
}

# Executar função principal
main "$@"
