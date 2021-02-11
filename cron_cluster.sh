#!/bin/bash
#############################################################################################
#
# ファイル名：cron_cluster.sh
#
# 処理内容：Cronクラスタ構成サーバ（2台）間でハートビート通信やインターネット疎通確認を行い
#           異常があればフェールオーバを実行する
# 引数    ：無し
# 実行契機：Cron 5秒間隔
# 戻り値  ：正常終了 0, 警告終了 1～4, 異常終了 8以上
# インプット  ： conf/cron_cluster.confから設定値を読み込む
# アウトプット： 無し
#
#############################################################################################
# 変数設定
BASEDIR="/hoge"
MYNAME=$(basename $0)
MYDIR=$(dirname $0)
CONFPATH="${BASEDIR}/conf"
## Cronクラスタ制御用変数読み込み
. ${CONFPATH}/cron_cluster.conf
## 自ホスト名設定
MYHOSTNAME=$(uname -n)
## AWS CLIパス設定
AWSCLI="/usr/local/bin/aws"
## クラスタ制御フラグ
CHK_FLAG=0
## フェールオーバ判定フラグ
FO_FLAG=0

# ２重起動抑止関数
function check_multiple() {
  OLDEST=$(pgrep -fo $0)
  if [[ "$$" != "${OLDEST}" ]] && [[ "${PPID}" != "${OLDEST}" ]]; then
    userlogger warning "既に実行されています"
    exit 4
  fi
}

# ログ出力関数（rsyslogを使ってます）
function cluster_logger() {
  local PRIORITY=${1}
  local MESSAGE=${2}
  logger -t ${MYNAME} -p local0.${PRIORITY} "${MESSAGE}"
}

# 事前処理関数
function pre_action() {
  ## /var/spool/cron のマウントチェック
  mount | grep -q "/var/spool/cron"
  if [[ $? -ne 0 ]]; then
    cluster_logger error "/var/spool/cron がマウントされていません"
    return 8
  fi

  ## ハートビート用の変数を設定
  if [[ ${MYHOSTNAME} == ${ACT_SERVER} ]]; then
    MY_SERVER_ID=${ACT_SERVER_ID}
    MY_IP_LOCAL=${ACT_SERVER_IP_LOCAL}
    MY_IP_LOCAL_2ND=${ACT_SERVER_IP_LOCAL_2ND}
    MY_IP_GLOBAL=${ACT_SERVER_IP_GLOBAL}
    MY_ALLOC_ID=${ACT_SERVER_IP_ALLOC_ID}
    PEER_HOSTNAME=${STB_SERVER}
    PEER_SERVER_ID=${STB_SERVER_ID}
    PEER_IP_LOCAL=${STB_SERVER_IP_LOCAL}
    PEER_IP_LOCAL_2ND=${STB_SERVER_IP_LOCAL_2ND}
    PEER_IP_GLOBAL=${STB_SERVER_IP_GLOBAL}
    PEER_ALLOC_ID=${STB_SERVER_IP_ALLOC_ID}
  elif [[ ${MYHOSTNAME} == ${STB_SERVER} ]]; then
    MY_SERVER_ID=${STB_SERVER_ID}
    MY_IP_LOCAL=${STB_SERVER_IP_LOCAL}
    MY_IP_LOCAL_2ND=${STB_SERVER_IP_LOCAL_2ND}
    MY_IP_GLOBAL=${STB_SERVER_IP_GLOBAL}
    MY_ALLOC_ID=${STB_SERVER_IP_ALLOC_ID}
    PEER_HOSTNAME=${ACT_SERVER}
    PEER_SERVER_ID=${ACT_SERVER_ID}
    PEER_IP_LOCAL=${ACT_SERVER_IP_LOCAL}
    PEER_IP_LOCAL_2ND=${ACT_SERVER_IP_LOCAL_2ND}
    PEER_IP_GLOBAL=${ACT_SERVER_IP_GLOBAL}
    PEER_ALLOC_ID=${ACT_SERVER_IP_ALLOC_ID}
  else
    cluster_logger error "ハートビート通信ができません。ホスト名と ${CONFPATH}/cron_cluster.conf の定義を合わせてください"
    return 8
  fi
}

# .cron.hostnameの内容チェック関数
function check_cron_hostname() {
  if [[ -r /var/spool/cron/.cron.hostname ]]; then
    ## 行数チェック
    ROW_COUNT=$(wc -l /var/spool/cron/.cron.hostname | awk '{print $1}')
    if [[ ${ROW_COUNT} -ne 1 ]]; then
      cluster_logger error ".cron.hostnameの行数が１でないため、内容を ${ACT_SERVER} に修正します修正前：[$(cat /var/spool/cron/.cron.hostname)]"
      fail_over ${ACT_SERVER}
      sleep ${FO_DELAY}
      return 8
    fi

    ## 内容チェック
    P_ACT_SERVER=$(cat /var/spool/cron/.cron.hostname)
    if [[ "${P_ACT_SERVER}" == "${ACT_SERVER}" ]] || [[ "${P_ACT_SERVER}" == "${STB_SERVER}" ]]; then
      true
    else
      cluster_logger error ".cron.hostnameの内容が不正なため、内容を ${ACT_SERVER} に修正します修正前：["${P_ACT_SERVER}"]"
      fail_over ${ACT_SERVER}
      sleep ${FO_DELAY}
      return 8
    fi
  fi
}

# Local IPへのpingによるハートビートチェック関数
function hb_ping_local() {
  CHK_FLAG=0
  for i in {0..2}; do
    ping -c ${PING_COUNT} -w ${PING_DEADLINE} ${PEER_IP_LOCAL} > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      cluster_logger warning "ピアサーバのローカルIP ${PEER_IP_LOCAL} へのPing失敗"
    else
      cluster_logger info "ピアサーバのローカルIP ${PEER_IP_LOCAL} へのPing成功"
      CHK_FLAG=1
      break
    fi
  done
  if [[ $CHK_FLAG -eq 0 ]]; then
    echo 1
  else
    echo 0
  fi

  return 0
}

# Global IPへのpingによるハートビートチェック関数
function hb_ping_global() {
  CHK_FLAG=0
  for i in {0..2}; do
    ping -c ${PING_COUNT} -w ${PING_DEADLINE} ${PEER_IP_GLOBAL} > /dev/null 2>&1
    if [[ $? -ne 0 ]]; then
      cluster_logger warning "ピアサーバのグローバルIP ${PEER_IP_GLOBAL} へのPing失敗"
    else
      cluster_logger info "ピアサーバのグローバルIP ${PEER_IP_GLOBAL} へのPing成功"
      CHK_FLAG=1
      break
    fi
  done
  if [[ $CHK_FLAG -eq 0 ]]; then
    echo 2
  else
    echo 0
  fi

  return 0
}

# インターネットウェブ疎通確認による自身の通信状況チェック関数
function hb_http() {
  CHK_FLAG=0
  for i in {0..2}; do
    ## google.comへの通信チェック
    curl -LI ${HTTP_CHECK_URL1} -o /dev/null -s -m ${CURL_TIMEOUT}
    if [[ $? -ne 0 ]]; then
      cluster_logger warning "${HTTP_CHECK_URL1} へのHTTP通信に失敗"
      ## yahoo.co.jp への通信チェック
      curl -LI ${HTTP_CHECK_URL2} -o /dev/null -s -m ${CURL_TIMEOUT}
      if [[ $? -ne 0 ]]; then
        cluster_logger warning "${HTTP_CHECK_URL2} へのHTTP通信に失敗"
      else
        cluster_logger info "${HTTP_CHECK_URL2} へのHTTP通信に成功"
        CHK_FLAG=1
        break
      fi
    else
      cluster_logger info "${HTTP_CHECK_URL1} へのHTTP通信に成功"
      CHK_FLAG=1
      break
    fi
  done
  if [[ $CHK_FLAG -eq 0 ]]; then
    echo 8
  else
    echo 0
  fi
}

# フェールオーバ関数
function fail_over() {
  cluster_logger error "フェールオーバを開始します"
  local RC=0
  ## 引数が無い場合、フェールオーバ実施（現在の現用待機関係を入れ替え）
  if [[ -z ${1} ]]; then
    ### 自身が現用系の場合、待機系へ降格
    if [[ ${P_ACT_SERVER} == ${MYHOSTNAME} ]]; then
      fail_over_to_standby
      RC=${?}
    ### 自身が待機系の場合、現用系へ昇格
    elif [[ ${P_ACT_SERVER} == ${PEER_HOSTNAME} ]]; then
      fail_over_to_active
      RC=${?}
    else
      cluster_logger error "ホスト名定義が正しくありません。${CONFPATH}/cron_cluster.conf の定義を確認してください"
      return 8
    fi
  elif [[ ${1} == ${MYHOSTNAME} ]]; then
    fail_over_to_active
    RC=${?}
  elif [[ ${1} == ${PEER_HOSTNAME} ]]; then
    fail_over_to_standby
    RC=${?}
  else
    cluster_logger warning "fail_over関数の引数が正しくありません。指定された引数：${1} 正しいホスト名を指定してください"
    RC=4
  fi

  if [[ ${RC} -ne 0 ]]; then
    cluster_logger error "フェールオーバに失敗しました"
  else
    cluster_logger error "フェールオーバに成功しました"
  fi

  return ${RC}
}

function fail_over_to_active() {
  cluster_logger notice "アクティブへの昇格処理を開始します"
  ## EIP付け替え
  ### ピアサーバのプライマリローカルIPにピアサーバのEIPをアタッチ
  ${AWSCLI} ec2 associate-address --instance-id ${PEER_SERVER_ID} --allocation-id ${PEER_ALLOC_ID} --private-ip-address ${PEER_IP_LOCAL} > /dev/null 2>&1
  if [[ ${?} -ne 0 ]]; then
    cluster_logger notice "アクティブへの昇格処理にてピアサーバへのEIP再アタッチに失敗しました"
    return 8
  else
    cluster_logger notice "アクティブへの昇格処理にてピアサーバへのEIP再アタッチに成功しました"
    ### 自サーバのプライマリローカルIPにクラスタ仮想IPをアタッチ
    ${AWSCLI} ec2 associate-address --instance-id ${MY_SERVER_ID} --allocation-id ${FLOATING_IP_ALLOC_ID} --private-ip-address ${MY_IP_LOCAL} > /dev/null 2>&1
    if [[ ${?} -ne 0 ]]; then
      cluster_logger notice "アクティブへの昇格処理にて自サーバへのクラスタ仮想IPアタッチに失敗しました"
      return 8
    else
      cluster_logger notice "アクティブへの昇格処理にて自サーバへのクラスタ仮想IPアタッチに成功しました"
      ### 自サーバのセカンダリローカルIPに自サーバのEIPをアタッチ
      ${AWSCLI} ec2 associate-address --instance-id ${MY_SERVER_ID} --allocation-id ${MY_ALLOC_ID} --private-ip-address ${MY_IP_LOCAL_2ND} > /dev/null 2>&1
      if [[ ${?} -ne 0 ]]; then
        cluster_logger notice "アクティブへの昇格処理にて自サーバへのEIP再アタッチに失敗しました"
        return 8
      else
        cluster_logger notice "アクティブへの昇格処理にて自サーバへのEIP再アタッチに成功しました"
        ${CRONTAB} -n ${MYHOSTNAME}
        cluster_logger notice "アクティブへの昇格処理が正常終了しました"
        return 0
      fi
    fi
  fi
}

# スタンバイへの降格処理
function fail_over_to_standby() {
  cluster_logger notice "スタンバイへの降格処理を開始します"
  ## EIP付け替え
  ### 自サーバのプライマリローカルIPに自サーバのEIPをアタッチ（クラスタ仮想IPがデタッチされる）
  ${AWSCLI} ec2 associate-address --instance-id ${MY_SERVER_ID} --allocation-id ${MY_ALLOC_ID} --private-ip-address ${MY_IP_LOCAL} > /dev/null 2>&1
  if [[ ${?} -ne 0 ]]; then
    cluster_logger error "スタンバイへの降格処理にて自サーバへのEIP再アタッチに失敗しました"
    return 8
  else
    cluster_logger notice "スタンバイへの降格処理にて自サーバへのEIP再アタッチに成功しました"
    ### ピアサーバのプライマリローカルIPにクラスタ仮想EIPをアタッチ
    ${AWSCLI} ec2 associate-address --instance-id ${PEER_SERVER_ID} --allocation-id ${FLOATING_IP_ALLOC_ID} --private-ip-address ${PEER_IP_LOCAL} > /dev/null 2>&1
    if [[ ${?} -ne 0 ]]; then
      cluster_logger error "スタンバイへの降格処理にてピアサーバへのクラスタ仮想IPのアタッチに失敗しました"
      return 8
    else
      cluster_logger notice "スタンバイへの降格処理にてピアサーバへのクラスタ仮想IPのアタッチに成功しました"
      ### ピアサーバのセカンダリローカルIPにピアサーバのEIPをアタッチ
      ${AWSCLI} ec2 associate-address --instance-id ${PEER_SERVER_ID} --allocation-id ${PEER_ALLOC_ID} --private-ip-address ${PEER_IP_LOCAL_2ND} > /dev/null 2>&1
      if [[ ${?} -ne 0 ]]; then
        cluster_logger error "スタンバイへの降格処理にてピアサーバへのEIP再アタッチに失敗しました"
        return 8
      else
        cluster_logger notice "スタンバイへの降格処理にてピアサーバへのEIP再アタッチに成功しました"
        ${CRONTAB} -n ${PEER_HOSTNAME}
        cluster_logger notice "スタンバイへの降格処理が正常終了しました"
        return 0
      fi
    fi
  fi
}

# メイン処理
function main() {
  check_multiple

  cluster_logger info "Cronクラスタ ハートビート処理を開始します"
  pre_action || exit ${?}
  check_cron_hostname || exit ${?}
  FO_FLAG=$((FO_FLAG + $(hb_ping_local)))
  FO_FLAG=$((FO_FLAG + $(hb_ping_global)))

  if [[ FO_FLAG -ge 3 ]]; then
    ## ピアサーバとのPing通信ができない場合、自サーバのNW状態をチェック
    FO_FLAG=$((FO_FLAG + $(hb_http)))
    P_ACT_SERVER=$(${CRONTAB} -c)
    if [[ ${FO_FLAG} -ge 11 ]]; then
      ## 自サーバのNW状態が不正の場合、アクティブならスタンバイへ降格
      if [[ ${P_ACT_SERVER} == ${MYHOSTNAME} ]]; then
        cluster_logger error "外部と通信ができません自サーバのネットワークがダウンしている可能性ありスタンバイへ降格します"
        fail_over
        sleep ${FO_DELAY}
      else
        cluster_logger error "外部と通信ができません自サーバのネットワークがダウンしている可能性ありスタンバイ状態を維持"
      fi
    else
      ## 自サーバのNW状態が正常の場合、スタンバイならアクティブへ昇格
      if [[ ${P_ACT_SERVER} == ${MYHOSTNAME} ]]; then
        cluster_logger error "ピアサーバのダウンを検知しましたアクティブ状態を維持"
      else
        cluster_logger error "ピアサーバのダウンを検知しましたアクティブへ昇格します"
        fail_over
        sleep ${FO_DELAY}
      fi
    fi
  fi

  cluster_logger info "Cronクラスタ ハートビート処理を終了します"
  exit 0
}

# 実行
main
