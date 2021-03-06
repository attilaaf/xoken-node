pipeline {
  agent any
  stages {
    stage('Prepare') {
      steps {
        sh 'mkdir -p arivi-core'
        dir(path: 'arivi-core') {
          git(url: 'https://github.com/xoken/arivi-core/', branch: 'master')
        }

        sh 'mkdir -p xoken-core'
        dir(path: 'xoken-core') {
          git(url: 'https://github.com/xoken/xoken-core/', branch: 'master')
        }

        sh 'mkdir -p xoken-node'
        dir(path: 'xoken-node') {
          git(url: 'https://github.com/xoken/xoken-node/', branch: "${env.BRANCH_NAME}")
        }

      }
    }

    stage('Clean') {
      steps {
        dir(path: 'xoken-node') {
          sh 'stack clean'
        }

      }
    }

    stage('Build') {
      steps {
        dir(path: 'xoken-node') {
          sh 'stack install  --local-bin-path  ../build/reg/'
          sh 'stack install  --executable-profiling  --local-bin-path  ../build/prof/'
        }

        archiveArtifacts(artifacts: 'build/**/xoken-nexa', followSymlinks: true)
      }
    }

    stage('Notify') {
      steps {
       echo 'done..'
      }
    }
    
    
  }
  
      post {
          unsuccessful {
                  emailext(subject: '$PROJECT_NAME - Build # $BUILD_NUMBER - $BUILD_STATUS!', body: '$PROJECT_NAME - Build # $BUILD_NUMBER - $BUILD_STATUS    ||   Please check attached logfile for more details.', attachLog: true, from: 'buildmaster@xoken.org', replyTo: 'buildmaster@xoken.org', to: 'jenkins-notifications@xoken.org')
           
          }
          fixed {
                  emailext(subject: '$PROJECT_NAME - Build # $BUILD_NUMBER - $BUILD_STATUS!', body: '$PROJECT_NAME - Build # $BUILD_NUMBER - $BUILD_STATUS  ||  Previous build was not successful and the current builds status is SUCCESS ||  Please check attached logfile for more details.', attachLog: true, from: 'buildmaster@xoken.org', replyTo: 'buildmaster@xoken.org', to: 'jenkins-notifications@xoken.org')
          }
      }
  
  
}
