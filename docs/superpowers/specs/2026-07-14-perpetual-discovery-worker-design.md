# Perpetual Discovery Worker（永続ディスカバリ・ワーカー）設計仕様

- 日付: 2026-07-14
- 対象リポジトリ: BioLabExplorer
- ステータス: Draft（ユーザーレビュー待ち）

## 1. 目的

既存の一発実行型「自律ディスカバリ」([`scripts/run_autonomous_discovery.sh`](../../../scripts/run_autonomous_discovery.sh)) を、
**新規候補を探索し続ける半永久ワーカー**へ拡張する。UniProt から入力バッチを回転取得し、
既発見を除外して**新規候補だけ**を蓄積・検証・可視化し、Mac(M5 Pro)の計算資源を
フルに使ってタンパク質シミュレーションを大量に回す。

## 2. 確定事項（Locked Decisions）

| 論点 | 決定 |
|---|---|
| 挙動 | 新規候補を探索し続ける（dedup 台帳で「新規のみ」を保証） |
| 入力 | UniProt 回転取得。`--allow-network` opt-in・host許可制・レート制限・承認済みクエリ範囲のみ |
| 常駐 | launchd `KeepAlive`（終了→即再起動）でサイクルを連続実行。重なり無し |
| ペース | 6h は「1サイクルのソフト予算」。早く終われば即次へ、長引けば新規ジョブを止めて終了→次へ |
| 上限 | サイクル数・出力に上限を設けない。ただしディスク空き**下限**で保護停止 |
| 計算 | フルスタック: ESMFold(MPS) + OpenMM(MD) + AutoDock Vina + ColabFold + Foldseek(バンドル) + mmseqs2 + HMMER。RAM予算スケジューラ＋グレースフル縮退 |
| 可視化 | 自己更新 HTML ダッシュボード＋**インタラクティブ3Dタンパク質ビューア**（3Dmol.js 同梱・**pLDDT信頼度で色分け**）。時系列/スコア分布/稼働状況も表示 |

## 3. 制約・非目標（AGENTS.md 準拠）

- `BioLabExplorerCore` は SwiftUI 非依存を維持。スコア定数はビューに置かない。
- 決定論的な Swift-native スコアが真実源。シミュ結果は**補助情報**（ランキングの主軸を乗っ取らない）。
- **ネットワークは既定 OFF**。opt-in 時も host 許可制（`rest.uniprot.org` / `alphafold.ebi.ac.uk` のみ）。
- **結果を外部に出さない**：`runs/` と台帳のみ。公開・送信・DB書込なし。通知は macOS ローカル通知のみ。
- 探索範囲は人間が承認した [`config/query_rotation.json`](../../../config/query_rotation.json) のみ。範囲変更は人手編集（バイオセキュリティ・レビュー要件）。
- 「無い外部ツールは可視化」：未導入バックエンドは dashboard で off 表示、ハード依存しない。

### 責任ある利用（Responsible Use）
本ワーカーは公開 UniProt の未特性化配列を、キュレート済み参照(PBP/PKS 等)に対して
**トリアージ（新規性ランキング＋構造的興味の一次評価）**する研究用途に限定する。
病原性の設計・強化は目的でも機能でもない。探索スコープの変更、参照セットの差し替え、
外部送信の追加は、いずれも人間の明示レビューを必須とする。

## 4. アーキテクチャ

### 1サイクルのデータフロー

```
launchd (KeepAlive) ──> scripts/run_discovery_cycle.sh   [1サイクル=有限実行/クリーン終了]
  1. preflight   : state/STOP チェック・ディスク空き下限・ツール可用性検出
  2. rotate      : state/rotation.json 読込 → 次クエリ確定（毎回前進）
  3. fetch       : [opt-in] UniProt から新バッチ取得（host許可制/レート制限/上限N配列）
                   ネットOFF時は state/inbox/*.fasta を消費、無ければ no-op で終了
  4. discover    : 既存 Swift-native 探索（curated referenceに対しk-mer/スコア）
  5. dedup       : discoveries/ledger.jsonl と突合（sha256(seq)+accession）→ 新規のみ通過
  6. simulate    : sim_queue.py が新規候補にフルスタックを RAM予算内で並列ディスパッチ
  7. record      : runs/cycle_<ts>/ に出力・ledger追記・DISCOVERIES.md追記・ローカル通知
  8. visualize   : discoveries/dashboard.html を再生成
  9. finalize    : rotation前進を確定・ログflush・exit(0)  (失敗は exit≠0 → launchdログ)
```

### ディレクトリ構成（新規追加）

```
scripts/
  run_discovery_cycle.sh        # 1サイクルの心臓部（オーケストレーション）
  sim_queue.py                  # フルスタックのRAM予算スケジューラ（python3）
  discovery_status.sh           # 稼働状況の可読サマリ
  install_discovery_agent.sh    # launchd の load/unload
  setup_simulation_stack.sh     # フルスタックの冪等インストーラ（conda/mamba）
config/
  query_rotation.json           # ★承認済みの探索範囲（クエリ集合＋ページング方針）
  worker.json                   # 実行パラメータ（予算・下限・レート等）
state/
  rotation.json                 # 回転カーソル（次に取りに行く場所）
  inbox/                        # オフライン時に人が置くFASTA（任意）
  STOP                          # 存在すれば次サイクルで安全停止（キルスイッチ）
discoveries/
  ledger.jsonl                  # dedup記憶：全既発見（1配列=1行）
  DISCOVERIES.md                # 新規ヒットだけが積み上がる可読ログ
  dashboard.html                # 自己更新ダッシュボード（generated）
launchd/
  com.biolab.discovery.plist    # KeepAlive 常駐定義
logs/
  cycle-<ts>.log                # 各サイクルのログ（既存 logs/ 配下）
```

## 5. コンポーネント（責務・IF・依存）

### 5.1 Cycle Runner — `run_discovery_cycle.sh`
- **責務**: 上記9ステップを1回だけ実行しクリーン終了。各ステップは独立コマンドで、途中失敗は非0終了。
- **IF**: 引数 `--allow-network`（既定OFF）、`--budget-seconds N`（既定21600）、`--dry-run`。
- **依存**: 既存探索実行体、`sim_queue.py`、`config/*.json`、`state/*`。

### 5.2 Rotation State — `state/rotation.json` ＋ `config/query_rotation.json`
- **責務**: 「次に何を取りに行くか」を持ち、毎サイクル前進させて入力を変え続ける。
- **契約(rotation.json)**: `{ "queryIndex": int, "offset": int, "updatedCycle": int }`
- **契約(query_rotation.json)**: `{ "queries": [{ "id": str, "uniprotQuery": str, "pageSize": 200, "maxOffset": int }], "policy": "advance-offset-then-next-query" }`
- **依存**: なし（純データ）。カーソルと台帳を**別ファイル**に分離（クラッシュ耐性）。

### 5.3 Network Fetcher（opt-in）
- **責務**: `--allow-network` 時のみ、rotation が指す UniProt REST クエリで新バッチを取得。
- **envelope**: host許可リスト固定、`User-Agent` 明示、リクエスト間 sleep（≥1s）、1サイクル上限200配列、タイムアウト、リトライ指数バックオフ。**読み取り専用**。
- **失敗時**: ネット不通/範囲尽きは soft-fail（ログ＋no-op終了、カーソルは進めない）。

### 5.4 Dedup Ledger — `discoveries/ledger.jsonl`
- **責務**: 既発見の単一真実源。冪等（同一配列の再報告を絶対にしない）。
- **契約(1行)**: `{ "seqSha256": str, "accession": str, "firstSeenCycle": int, "score": float, "verdict": str, "ts": str }`
- **dedupキー**: `seqSha256` OR `accession`。近傍重複クラスタリング（k-mer類似）は将来拡張。

### 5.5 Discovery/Search Stage（既存再利用）
- **責務**: 取得バッチを curated reference に対し Swift-native で探索・スコア。
- **依存**: 既存 [`run_public_probe.sh`](../../../scripts/run_public_probe.sh) 相当のロジック／`BioLabExplorerStructureCheck`。契約は変更しない。

### 5.6 Simulation Job Queue — `sim_queue.py`（フルスタックの中核）
- **責務**: 新規候補に対し、利用可能バックエンドを **RAM予算内で並列**実行し、結果を候補に添付。
- **バックエンドと役割**:
  | ツール | 役割 | 概算RAM/ジョブ | 既定同時数 |
  |---|---|---|---|
  | AutoDock Vina | ドッキング一次スクリーニング | ~0.5–1GB | 多数(コア律速) |
  | ESMFold(torch-MPS) | 全新規候補の高速folding | ~2–4GB | 2–3 |
  | OpenMM(CPU) | 予測構造のMD緩和/短時間シミュ | ~1–2GB | 2–4 |
  | Foldseek(バンドル) | 予測構造の構造検索 | ~1GB | 多数 |
  | ColabFold | **上位候補のみ**深掘りfolding | ~6–12GB | 1 |
- **スケジューラ**: RAM予算 = `min(config, 総RAM - reserve(既定6GB))`。`Σ 見積RAM ≤ 予算` を満たす範囲で投入、空けば次を投入。MPS系はGPU直列化を尊重。
- **縮退**: 未導入/失敗バックエンドはスキップし、最終的に Swift-native の軽量検証へフォールバック。1件も倒れない。
- **時間予算**: `--budget-seconds` 到達で新規投入を停止、実行中は完了まで待って終了（重なり回避）。
- **IF**: `sim_queue.py --candidates <json> --budget-seconds N --ram-budget-gb G` → 結果JSONを返す。

### 5.7 Recorder
- **責務**: `runs/cycle_<ts>/`（レポート/構造/JSON）を書き、`ledger.jsonl` 追記、`DISCOVERIES.md` に新規のみ追記、macOS ローカル通知。`.complete` マーカーで完了明示（既存慣習踏襲）。

### 5.8 Dashboard ＋ Protein Structure Viewer（可視化）

**Dashboard Generator**
- **責務**: `ledger.jsonl` と `runs/` を読み、自己完結HTMLを再生成。CDN非依存（アセット全同梱）。時系列・スコア分布・稼働状況を表示。

**Protein Structure Viewer（第一級・インタラクティブ3D）**
- **責務**: 各候補の予測構造(ESMFold/ColabFold の PDB)または AlphaFold キャッシュを **3Dmol.js(同梱)** で回転/ズーム表示。**pLDDT 信頼度**で残基を色分け（青=高信頼〜橙=低信頼）。
- **素材**: `runs/cycle_<ts>/native_structures/*.pdb`（pLDDT = PDB の B-factor 列 / ColabFold の scores JSON）。予測が無い候補は「構造未予測」表示でフォールバック。
- **配置**: ダッシュボード内に候補ごとの展開ビュー＋上位候補ギャラリー。SwiftUIアプリからは WKWebView で同ビューアを再利用可能（将来）。
- **依存**: sim_queue の folding 出力・AlphaFold キャッシュ。CDN非依存。
- **将来拡張（今回スコープ外）**: 参照へのスーパーインポーズ・2D距離/コンタクトマップ・ドッキングポーズ。

### 5.9 launchd Agent ＋ Installer
- **責務**: `com.biolab.discovery.plist`（`KeepAlive=true`、`ThrottleInterval` で最小間隔、`RunAtLoad`、stdout/err→`logs/`）。`install_discovery_agent.sh` で load/unload/status。

### 5.10 Guardrails / Status / Kill-switch
- `state/STOP` 存在→次サイクルで安全停止。
- ディスク空き下限（既定10GB）割れ→保護停止＋通知（出力上限ではない）。
- `discovery_status.sh`：サイクル数・最終実行・新規累計・カーソル・次クエリ・ネット可否・ツール可用・ディスク・実行中ジョブ。

## 6. 安全 envelope（再掲・要点）
- ネット既定OFF / opt-in時も host許可制・レート制限・読取専用・範囲は承認済みJSONのみ。
- 結果は一切外部送信しない。通知はローカルのみ。
- ディスク保護停止・キルスイッチ・重なり回避。
- バイオセキュリティ: 参照/スコープ変更は人手レビュー必須（§3 Responsible Use）。

## 7. テスト（既存の実行体チェック方式）
`BioLabExplorerChecks` またはシェルテストで:
1. dedup 冪等性（同一配列を二度通しても新規報告0）。
2. カーソル前進（サイクル毎に rotation.json が進む／クラッシュ後も不整合なし）。
3. オフライン既定の no-op（`--allow-network` 無しでネットに触れない）。
4. ガードレール発火（STOP・ディスク下限・時間予算での新規停止）。
5. RAM予算スケジューラ（見積合計が予算を超えない／縮退でフォールバック）。

## 8. ビルド順（マイルストーン）
1. **M1 骨格（オフライン）**: cycle runner＋rotation＋ledger＋recorder＋status。`state/inbox` 消費で新規のみ蓄積。テスト1–4。
2. **M2 常駐化**: launchd plist＋installer。KeepAlive連続実行・重なり回避・時間予算。
3. **M3 ネット回転(opt-in)**: UniProt fetcher＋envelope。範囲JSON承認フロー。
4. **M4 可視化**: dashboard generator ＋ **インタラクティブ3Dタンパク質ビューア(3Dmol.js同梱・pLDDT色分け)**。M4 時点は AlphaFold キャッシュ／「未予測」フォールバックで成立し、M5 の folding 出力で素材が充実する。
5. **M5 フルスタック計算**: `setup_simulation_stack.sh`＋`sim_queue.py`（RAM予算・縮退）。ESMFold→OpenMM→Vina→ColabFold(上位のみ)→Foldseek。テスト5。

各マイルストーンは独立に価値があり、M1時点で「新規のみ蓄積する半永久ワーカー」として成立する。

## 9. 前提・未決
- `setup_simulation_stack.sh` の実行（多GB DL・ネット）は**ユーザー承認のもとで実施**。Claude は無断でインストール/ネットアクセスしない。
- ColabFold は 24GB では MSA が重いため既定は reduced-MSA/上位候補限定。必要なら後で調整。
- 3Dmol.js の同梱方法（ベンダリング）は M4 で確定。pLDDT は PDB の B-factor 列（AlphaFold/ESMFold 慣習）を既定の色分けソースとし、ColabFold は scores JSON を併用。
