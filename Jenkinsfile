pipeline {
    agent any

    options {
        skipDefaultCheckout()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '15'))
    }

    triggers {
        pollSCM('H/2 * * * *')
    }

    environment {
        APP_NAME       = 'university-lms'
        IMAGE_REPO     = 'adityarajarora123/university-lms'
        IMAGE_TAG      = "v1.0.${env.BUILD_NUMBER}"
        TEST_CONTAINER = "university-lms-test-${env.BUILD_NUMBER}"
        NODE_PORT      = '30081'
        DOCKERHUB      = credentials('dockerhub')
        KUBECONFIG     = credentials('kubeconfig')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Build Image') {
            steps {
                script {
                    run "docker build --build-arg APP_VERSION=${IMAGE_TAG} -t ${IMAGE_REPO}:${IMAGE_TAG} ."
                }
            }
        }

        stage('Test Image') {
            steps {
                script {
                    run "docker run -d --name ${TEST_CONTAINER} ${IMAGE_REPO}:${IMAGE_TAG}"
                    run "docker exec -i ${TEST_CONTAINER} sh -s http://127.0.0.1 < ${localPath('tests/smoke-test.sh')}"
                }
            }
            post {
                always {
                    script { runStatus("docker rm -f ${TEST_CONTAINER}") }
                }
            }
        }

        stage('Push Image') {
            steps {
                script {
                    dockerLogin()
                    run "docker push ${IMAGE_REPO}:${IMAGE_TAG}"
                }
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                script {
                    renderManifest('deployment.yaml', 'deployment.rendered.yaml')
                    run 'kubectl apply -f service.yaml'
                    run 'kubectl apply -f deployment.rendered.yaml'
                }
            }
        }

        stage('Health Check') {
            steps {
                script {
                    boolean healthy = runStatus("kubectl rollout status deployment/${APP_NAME} --timeout=120s") == 0
                    if (healthy) {
                        healthy = runStatus("kubectl exec -i deployment/${APP_NAME} -- sh -s http://${APP_NAME} < ${localPath('tests/smoke-test.sh')}") == 0
                    }
                    if (!healthy) {
                        rollbackRelease(APP_NAME)
                        error "Release ${IMAGE_TAG} failed its health checks and was rolled back to the previous stable revision."
                    }
                }
            }
        }

        stage('Promote Stable Release') {
            steps {
                script {
                    run "docker tag ${IMAGE_REPO}:${IMAGE_TAG} ${IMAGE_REPO}:stable"
                    run "docker tag ${IMAGE_REPO}:${IMAGE_TAG} ${IMAGE_REPO}:latest"
                    run "docker push ${IMAGE_REPO}:stable"
                    run "docker push ${IMAGE_REPO}:latest"
                    run "kubectl get deployment,pods,service -l app=${APP_NAME} -o wide"
                    run "kubectl rollout history deployment/${APP_NAME}"
                }
            }
        }
    }

    post {
        success {
            echo "Release ${IMAGE_TAG} is live at http://localhost:${NODE_PORT}"
        }
        failure {
            echo "Pipeline failed for release ${IMAGE_TAG}. Check the stage logs above."
        }
        always {
            script { runStatus('docker logout') }
        }
    }
}

def run(String command) {
    if (isUnix()) {
        sh command
    } else {
        bat command
    }
}

def runStatus(String command) {
    return isUnix() ? sh(script: command, returnStatus: true) : bat(script: command, returnStatus: true)
}

def localPath(String path) {
    return isUnix() ? path : path.replace('/', '\\')
}

def dockerLogin() {
    if (isUnix()) {
        sh 'echo "$DOCKERHUB_PSW" | docker login -u "$DOCKERHUB_USR" --password-stdin'
    } else {
        bat '@echo %DOCKERHUB_PSW%| docker login -u %DOCKERHUB_USR% --password-stdin'
    }
}

def renderManifest(String source, String target) {
    String manifest = readFile(source)
        .replace("${env.IMAGE_REPO}:latest", "${env.IMAGE_REPO}:${env.IMAGE_TAG}")
        .replace('Initial release', "Build #${env.BUILD_NUMBER} - ${env.IMAGE_TAG}")
    writeFile file: target, text: manifest
}

def rollbackRelease(String deployment) {
    echo "Rollout of ${env.IMAGE_TAG} failed. Collecting diagnostics before rolling back."
    runStatus("kubectl get pods -l app=${deployment} -o wide")
    runStatus('kubectl get events --field-selector type=Warning --sort-by=.lastTimestamp')
    run "kubectl rollout undo deployment/${deployment}"
    run "kubectl rollout status deployment/${deployment} --timeout=120s"
    run "kubectl rollout history deployment/${deployment}"
    run "kubectl get pods -l app=${deployment} -o wide"
}
