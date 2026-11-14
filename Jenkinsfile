pipeline {
    agent { label 'devloom-docker' }

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '15'))
        timeout(time: 90, unit: 'MINUTES')
    }

    parameters {
        booleanParam(name: 'RUN_PRODUCTION_SMOKE', defaultValue: true,
            description: 'Exercise the production image locally, including HTTPS and database backup/restore.')
        booleanParam(name: 'DEPLOY_PRODUCTION', defaultValue: false,
            description: 'Plan a VPS deployment from main, then wait for approval. Requires production credentials.')
    }

    // Polling works with Jenkins on localhost; no public webhook or tunnel is required.
    triggers { pollSCM('H/5 * * * *') }

    stages {
        stage('Checkout') {
            steps {
                deleteDir()
                checkout scm
                script {
                    env.CI_PROJECT_NAME = 'devloom-ci-' + sh(
                        script: 'printf %s "$BUILD_TAG" | sha256sum | cut -c1-16',
                        returnStdout: true
                    ).trim()
                    env.CI_REVISION = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                }
            }
        }

        stage('Prepare CI') {
            steps { sh 'bash infra/jenkins/ci/run.sh prepare' }
        }

        stage('Formatting and compilation') {
            steps { sh 'bash infra/jenkins/ci/run.sh check' }
        }

        stage('Phoenix tests') {
            steps { sh 'bash infra/jenkins/ci/run.sh test' }
        }

        stage('JavaScript tests') {
            steps { sh 'bash infra/jenkins/ci/run.sh javascript' }
        }

        stage('Deployment configuration tests') {
            steps { sh 'bash infra/jenkins/ci/run.sh infra' }
        }

        stage('Production image') {
            steps { sh 'bash infra/jenkins/ci/run.sh build' }
        }

        stage('Local production smoke test') {
            when { expression { params.RUN_PRODUCTION_SMOKE } }
            steps { sh 'bash infra/jenkins/ci/run.sh smoke' }
        }

        stage('VPS deployment') {
            when { expression { params.DEPLOY_PRODUCTION } }
            steps {
                script {
                    def sourceBranch = env.BRANCH_NAME ?: env.GIT_LOCAL_BRANCH ?: env.GIT_BRANCH
                    if (env.CHANGE_ID || !(sourceBranch in ['main', 'origin/main'])) {
                        error('Production deployment is allowed only from a trusted main-branch job.')
                    }
                    if (!params.RUN_PRODUCTION_SMOKE) {
                        error('Production deployment requires RUN_PRODUCTION_SMOKE=true.')
                    }
                    if (!(env.GIT_URL in ['https://github.com/shashankfeb16/devloom.git',
                                          'git@github.com:shashankfeb16/devloom.git'])) {
                        error('Production deployment requires the GitHub repository, not a local test snapshot.')
                    }
                }
                lock(resource: 'devloom-production') {
                    withCredentials([file(credentialsId: 'devloom-production-config', variable: 'DEVLOOM_DEPLOY_CONFIG')]) {
                        sshagent(credentials: ['devloom-vps-ssh']) {
                            sh 'bash infra/jenkins/deploy/run.sh plan'
                            timeout(time: 15, unit: 'MINUTES') {
                                input message: "Apply the reviewed VPS plan for commit ${env.CI_REVISION}?", ok: 'Deploy Devloom'
                            }
                            sh 'bash infra/jenkins/deploy/run.sh apply'
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            script {
                if (env.CI_PROJECT_NAME && fileExists('infra/jenkins/ci/run.sh')) {
                    sh returnStatus: true, script: 'bash infra/jenkins/ci/run.sh cleanup'
                }
                if (fileExists('infra/jenkins/deploy/run.sh')) {
                    sh returnStatus: true, script: 'bash infra/jenkins/deploy/run.sh cleanup'
                }
            }
        }
    }
}
