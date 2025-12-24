pipeline {
    agent any

    stages {
        stage('Build Artifact') {
            steps {
                sh "mvn clean package -DskipTests=true"
                archiveArtifacts 'target/*.jar'
            }

        }

        stage('Unit Test') {
            steps {
                sh "mvn test"
            }
            post {
                always {
                    junit 'target/surefire-reports/*.xml'
                    jacoco execPattern: 'target/jacoco.exec'
                }
            }
        }

        stage('Docker Build and Push') {
            steps {
                // use docker hub credentials
                 withDockerRegistry([credentialsId: "docker-hub", url: ""]) {
                    // prints all the jenkins env variables
                    sh 'printenv' 
                    sh 'docker build -t cmandolk/numeric-app:${GIT_COMMIT} .'
                    sh 'docker push cmandolk/numeric-app:${GIT_COMMIT}'
                }

            }
        }

        stage('Kubernetes Deployment-Dev') {
            steps {
                 withKubeConfig([credentialsId: "kubeconfig"]) {
                    // prints all the jenkins env variables
                    sh 'sed -i "s|replace|cmandolk/numeric-app:${GIT_COMMIT}|g" k8s_deployment_service.yaml' 
                    sh 'kubectl apply -f k8s_deployment_service.yaml'
                }

            }
        }
    }
}