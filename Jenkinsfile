pipeline {
    agent any
      tools {
        // a bit ugly because there is no `@Symbol` annotation for the DockerTool
        // see the discussion about this in PR 77 and PR 52: 
        // https://github.com/jenkinsci/docker-commons-plugin/pull/77#discussion_r280910822
        // https://github.com/jenkinsci/docker-commons-plugin/pull/52
        'org.jenkinsci.plugins.docker.commons.tools.DockerTool' '18.09'
    }
    environment {
        DOCKER_CERT_PATH = credentials('docker-hub')
    }

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
                with
                // prints all the jenkins env variables
                sh 'printenv' 
                sh 'docker build -t cmandolk/numeric-app:""$GIT-COMMIT"" .'
                sh 'docker push cmandolk/numeric-app:""$GIT-COMMIT""'
            }
        }
    }
}