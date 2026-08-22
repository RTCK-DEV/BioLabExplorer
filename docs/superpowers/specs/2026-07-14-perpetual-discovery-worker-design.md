# Perpetual Discovery Worker（永続ディスカバリ・ワーカー）設計仕様

- 日付: 2026-07-14
- 対象リポジトリ: BioLabExplorer
- ステータス: Implemented（core M1–M5、2026-07-15 release audit 対象）

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
| 上限 | サイクル数に上限なし。ただし**容量 quota**(`maxWorkspaceBytes`/`maxLogFiles`)＋ディスク空き下限で保護停止。worker所有の temp/log のみ自動剪定(`runs/`等は削除しない＝AGENTS.md準拠)。連続失敗で**サーキットブレーカ**(PAUSED) |
| 計算 | ESMFold-compatible CLI adapter + OpenMM(energy minimization・スレッド制限) + AutoDock Vina + Foldseek(バンドル) + mmseqs2 + HMMER。MMseqs2/HMMERはmulti-FASTAを一括検索し、実測に基づく1:2 CPU重みで全論理コアを配分する。Apple Silicon向けinstallerは検証不能なfair-esm MPS環境を捏造せず、ESMFold CLIが別途存在するときだけ検出する。**ColabFold は現行非アクティブ**(24GBローカル不可・生FASTAは公開MSAサーバ問い合わせ=host許可制違反。External MSA Storeはpost-M5設計予約)。RAM予算スケジューラ(予約8–10GB・memory_pressure監視・per-tool timeout)＋グレースフル縮退 |
| 可視化 | 自己更新 HTML ダッシュボード＋**インタラクティブ3Dタンパク質ビューア**（3Dmol.js 同梱・**pLDDT信頼度で色分け**）。時系列/スコア分布/稼働状況も表示 |

## 3. 制約・非目標（AGENTS.md 準拠）

- `BioLabExplorerCore` は SwiftUI 非依存を維持。スコア定数はビューに置かない。
- 決定論的な Swift-native スコアが真実源。シミュ結果は**補助情報**（ランキングの主軸を乗っ取らない）。
- **ネットワークは実行単位で既定 OFF**（`--allow-network` またはdaemon生成時の明示環境変数が必要）。2026-07-15の承認後、チェックイン済み運用設定は `enableNetwork: true`。opt-in 時も host 許可制（`rest.uniprot.org` / `alphafold.ebi.ac.uk` のみ）。
- **結果を外部に出さない**：`runs/` と台帳のみ。公開・送信・DB書込なし。通知は macOS ローカル通知のみ。
- 探索範囲は人間が承認した [`config/query_rotation.json`](../../../config/query_rotation.json) のみ。範囲変更は人手編集（バイオセキュリティ・レビュー要件）。
- 「無い外部ツールは可視化」：未導入バックエンドは dashboard で off 表示、ハード依存しない。

### 責任ある利用（Responsible Use）
本ワーカーは公開 UniProt の未特性化配列を、キュレート済み参照(PBP/PKS 等)に対して
**トリアージ（新規性ランキング＋構造的興味の一次評価）**する研究用途に限定する。
病原性の設計・強化は目的でも機能でもない。これは公開データの正当な研究トリアージであり、
配列設計・合成・強化のいずれも行わない（全レビュー一致の結論）。

**スコープの明文境界（enforced）**:
- 承認済みの参照集合と `query_rotation.json` は、**毒素・病原性因子・toxin biosynthesis gene cluster・select-agent 相同体を除外**する。除外規定は `config/approved_manifest.json` に明記。
- 参照/クエリ集合は **digest で fail-closed**（一致しなければ実行中止）。来歴（reviewer/date/digest）を記録し、スコープ変更時のレビューで除外の充足を明示的に attest する。
- `DISCOVERIES.md`・ダッシュボードに intended-use ヘッダ（「未検証の in-silico 予測・外部利用/公開/wet-lab 引渡しは要レビュー」）を付す。
- 生成物は git 追跡外（ローカルのみ）。標的/リガンドの拡張、病原性志向のスコープ、外部送信・公開、生成的配列設計、wet-lab 引渡しは**新規レビュー必須**。
探索スコープの変更、参照セットの差し替え、外部送信の追加は、いずれも人間の明示レビューを必須とする。

## 4. アーキテクチャ

### 1サイクルのデータフロー

```
launchd (KeepAlive) ──> scripts/run_discovery_cycle.sh   [1サイクル=有限実行/クリーン終了]
  1. preflight   : state/STOP チェック・ディスク空き下限・ツール可用性検出
  2. rotate      : state/rotation.json 読込 → 次クエリ確定（毎回前進）
  3. fetch       : [opt-in] UniProt から新バッチ取得（host許可制/レート制限/上限N配列）
                   ネットOFF時は state/inbox/*.fasta を消費、無ければ no-op で終了
  4. discover    : 既存 Swift-native 探索（curated referenceに対しk-mer/スコア）
  5. dedup       : discoveries/ledger.db と突合（sha256(seq)）→ 新規のみ通過
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
  discovery_agent.sh            # launchd plist生成＋load/unload/status/resume
  setup_simulation_stack.sh     # フルスタックの冪等インストーラ（conda/mamba）
config/
  query_rotation.json           # ★承認済みの探索範囲（クエリ集合＋ページング方針）
  worker.json                   # 実行パラメータ（予算・下限・レート等）
state/
  rotation.json                 # 回転カーソル（次に取りに行く場所）
  inbox/                        # オフライン時に人が置くFASTA（任意）
  STOP                          # 存在すれば次サイクルで安全停止（キルスイッチ）
discoveries/
  ledger.db                     # SQLite dedup台帳：全処理配列＋後段用sequence payload
  DISCOVERIES.md                # 新規ヒットだけが積み上がる可読ログ
  dashboard.html                # 自己更新ダッシュボード（generated）
~/Library/LaunchAgents/
  com.biolab.discovery.plist    # discovery_agent.sh install が生成する常駐定義
logs/
  cycle-<ts>.log                # 各サイクルのログ（既存 logs/ 配下）
```

## 5. コンポーネント（責務・IF・依存）

### 5.1 Cycle Runner — `run_discovery_cycle.sh`
- **責務**: 上記9ステップを1回だけ実行しクリーン終了。各ステップは独立コマンドで、途中失敗は非0終了。
- **IF**: 引数 `--allow-network`（既定OFF）、`--budget-seconds N`（既定21600）、`--dry-run`。
- **依存**: 既存探索実行体、`sim_queue.py`、`config/*.json`、`state/*`。

### 5.2 Rotation State — `state/rotation.json` ＋ `config/query_rotation.json`
- **責務**: 「次に何を取りに行くか」を持ち、毎サイクル前進させて入力を変え続ける。すべて `schemaVersion` 付き。
- **契約(rotation.json)**: `{ "schemaVersion": 1, "queryId": str, "approvedQueryDigest": str, "nextCursor": str|null, "cycle": int, "updatedCycle": int, "lastRunId": str }`。M1 はオフラインの縮退形 `{ "schemaVersion", "cycle", "updatedCycle", "lastRunId" }` を使い、`queryId/nextCursor` は M3 で追加。
- **UniProt ページング**: **不透明カーソル(`Link: rel=next`)** を state に保存して辿る。数値 offset は生 DB のエントリ移動で取りこぼし/重複が起きるため使わない。
- **契約(query_rotation.json)**: `{ "schemaVersion": 1, "queries": [{ "id": str, "uniprotQuery": str, "pageSize"?: 1...200 }] }`（承認済みクエリ集合。省略時はworkerの `fetchPageSize`、上限200。digest を rotation に記録）。cursorは `approvedQueryDigest`＋`queryId`に束縛し、legacy/unbound cursorまたはdigest変更時は破棄して先頭から安全に再開する。
- **依存**: なし（純データ）。カーソルと台帳を**別ファイル**に分離（クラッシュ耐性）。書込は temp+`os.replace` の原子的更新。

### 5.3 Network Fetcher（opt-in）
- **責務**: `--allow-network` 時のみ、rotation が指す UniProt REST クエリで新バッチを取得。
- **envelope**: host許可リスト固定、`User-Agent` 明示、リクエスト間 sleep（≥1s）、1サイクル上限200配列、タイムアウト、リトライ指数バックオフ。**読み取り専用**。
- **失敗時**: ネット不通・429・retryable 5xxは専用終了コード75でsoft-fail（ログ＋no-op終了、カーソルは進めない）。host/path/query/format/digest/レスポンス契約違反や非retryable HTTPはhard-fail（非0）し、成功に見せない。

### 5.4 Seen-set Ledger — `discoveries/ledger.db`（**SQLite・stdlib**）
- **責務**: 処理済み配列の単一真実源（seen-set）。**処理した全配列**を記録し、該当を `verdict='actionable'` に。冪等・クラッシュ整合を PRIMARY KEY＋単一トランザクションで担保。
- **identity**: `seq_sha256`（配列の大文字正規化 sha256）を PRIMARY KEY＝dedup キー。`accession` は provenance（同一 accession の配列改訂は別 identity として記録）。
- **スキーマ v2**: `processed(seq_sha256 PK, accession, sequence, verdict CHECK(actionable|screened), score, classification, first_seen_cycle, run_id, ts, schema_version)`。v1 DB は additive migration で `sequence` を追加し、既存行を失わない。新規 actionable 行は simulation 用に完全な配列 payload を保持する。
- **書込**: `INSERT OR IGNORE` を1トランザクションで実行→バッチ内重複も自動排除。新規 actionable 件数は `rowcount==1 && actionable` で厳密カウント（全件スキャン不要）。
- **`DISCOVERIES.md`**: 台帳から毎サイクル**再生成**（temp+`os.replace`）。二重書き込みによるクラッシュ不整合を排除。`ledger.db`・`DISCOVERIES.md` とも **git 追跡外（ローカルのみ）**。
- **actionable 定義**: `DiscoveryValidator.qualifyingCandidateIDs` を再利用（独自閾値を作らない）。

### 5.5 Discovery/Search Stage（既存再利用）
- **責務**: 取得バッチを curated reference に対し Swift-native で探索・スコア。
- **依存**: 既存 [`run_public_probe.sh`](../../../scripts/run_public_probe.sh) 相当のロジック／`BioLabExplorerStructureCheck`。契約は変更しない。

### 5.6 Simulation Job Queue — `sim_queue.py`（フルスタックの中核）
- **責務**: 新規候補に対し、利用可能バックエンドを **RAM予算内で並列**実行し、結果を候補に添付。
- **バックエンドと役割**:
  | ツール | 役割 | 概算RAM/ジョブ | 既定同時数 |
  |---|---|---|---|
  | MMseqs2 | 候補バッチ対参照の配列検索 | ~1GB | 1バッチ(スレッド分割) |
  | HMMER/phmmer | 候補バッチ対参照のプロファイル検索 | ~0.5GB | 1バッチ(スレッド分割) |
  | AutoDock Vina + Meeko | 緩和後PDBのreceptor調製＋manifest承認ligandの一次スクリーニング | ~0.5–1GB | コア律速 |
  | revision-pinned Hugging Face ESMFold / compatible CLI | 全新規候補のfolding | 長さ依存(重み~5GB+・trunk O(L²)) | MPS/GPU直列 |
  | PDBFixer + OpenMM(CPU) | 欠損重原子補修（欠損残基生成なし）＋energy minimization | ~1–2GB | 1 thread（決定性優先） |
  | Foldseek(バンドル) | 予測構造の構造検索 | ~1GB | 多数 |
- **ColabFold は既定 OFF**: 生FASTAは公開MSAサーバへ問い合わせ(host許可制違反)、完全ローカルMSAは約940GB DB＋約128GB RAM で 24GB では搭載不可。よって既定では使わない。
- **設計予約（post-M5、現行は非アクティブ）: External MSA Store**: 将来、外部ストレージ（マウント済みボリューム `externalMsaStorePath`）に **事前計算済み MSA（a3m）** と完全ローカルなmodel cacheを置く経路を別レビュー後に実装する。現行の予約キーを設定しても起動しない。
  - **適用範囲の線引き**: この経路は **外部の precomputed MSA を読み込んで folding するのみ**。940GB DB を外部に置いても、ローカルでの MSA 検索は依然 ~128GB RAM を要し 24GB では不可なので、**MSA 検索は行わず precomputed a3m を使う**運用に限定する。
  - **将来のenvelope**: 公開 MSA サーバには**絶対に問い合わせない**（precomputed/local のみ）。外部ストアの MSA も承認 manifest のスコープ・provenance に従う。ストアまたは検証済みlocal folding backendが無い場合は unavailable を可視化する。現行core M5にはこの経路を接続しない。
- **スケジューラ**: RAM予算 = `min(config, 総RAM - reserve(既定8–10GB))`。**配列長を考慮した入場クラス**で `Σ 見積RAM ≤ 予算` を満たす範囲で動的投入し、完了時に予約を返して pending job を再充填する。MMseqs2/HMMER は候補をバッチ化して参照 DB の再走査を避け、同時実行時は CPU thread を分割する。MPS系はGPU直列化。`memory_pressure` 監視で逼迫時は新規投入停止。**per-tool timeout＋プロセスグループ単位TERM→grace→KILL**、投入締切は shutdown 時間を確保。長い配列は folding 前に max-length ゲート。
- **構造直列契約**: `sequence -> folding -> PDBFixer -> OpenMM -> Meeko -> Vina -> 3Dmol`。Vina/Foldseek は必ずOpenMM成功出力だけを読む。各handoffのSHA-256、model revision、補修原子数、初期/最終energy、motif anchor/box/seed/全affinityを保存する。AlphaFold cache利用時は`alphafold-cache`と明記し、local folding実行とは数えない。
- **実機リリース検証（2026-07-15）**: 24 GiB Apple Silicon 上で、承認済みPBP候補 `A0A062TNK1`（668 aa）を同一配列のまま ESMFold(MPS) → PDBFixer/OpenMM(CPU) → Meeko/Vina(15 threads) に通し、655.97秒・最大process RSS 5.16 GB・swap 0・failed 0。ESMFold平均pLDDT 94.59、OpenMM energy drop 55,690.39 kJ/mol、固定seed Vina best affinity -8.317 kcal/mol。folding出力→OpenMM入力、およびOpenMM出力→Vina receptor入力のSHA-256一致を確認した。これらは予測信頼度・仮説順位であり、実験的な生物学的妥当性とは扱わない。
- **縮退**: 未導入バックエンドは理由付きでスキップし、Swift-native の軽量検証結果を失わない。ただし実行したscientific backendの失敗は`failed`として可視化し、空成功にしない。
- **時間予算**: `--budget-seconds` 到達で新規投入を停止、実行中は完了まで待って終了（重なり回避）。
- **IF**: `sim_queue.py --candidates <json> --budget-seconds N --ram-budget-gb G` → 結果JSONを返す。

### 5.7 Recorder
- **責務**: `runs/cycle_<ts>/`（レポート/構造/JSON）を書き、SQLite transaction で `ledger.db` を更新し、そこから `DISCOVERIES.md` を原子的再生成する。macOS ローカル通知は durable commit 後のみ実行し、`.complete` / `.failed` マーカーで終了状態を明示する。

### 5.8 Dashboard ＋ Protein Structure Viewer（可視化）

**Dashboard Generator**
- **責務**: `ledger.db` と `runs/` の最新 simulation summary を読み、自己完結HTMLを再生成。CDN非依存（アセット全同梱）。時系列・スコア分布・backend可用性・CPU/RAM稼働状況を表示。

**Protein Structure Viewer（第一級・インタラクティブ3D）**
- **責務**: 各候補のOpenMM緩和構造（無ければ予測構造/AlphaFold cache）とVina poseを **3Dmol.js(同梱)** で回転/ズーム表示。**pLDDT 信頼度**で残基を色分けし、全体/ドッキング部位focusとPNG exportを提供する。
- **素材**: `runs/cycle_<ts>/native_structures/*.pdb`（pLDDT = PDB の B-factor 列 / ColabFold の scores JSON）。予測が無い候補は「構造未予測」表示でフォールバック。
- **配置**: ダッシュボード内に候補ごとの展開ビュー＋上位候補ギャラリー。SwiftUIアプリからは WKWebView で同ビューアを再利用可能（将来）。
- **依存**: sim_queue の folding 出力・AlphaFold キャッシュ。CDN非依存。
- **将来拡張**: 参照へのスーパーインポーズ・2D距離/コンタクトマップ。

### 5.9 launchd Agent ＋ Installer
- **責務**: `com.biolab.discovery.plist`（`KeepAlive=true`、`ThrottleInterval` で最小間隔、`RunAtLoad`、stdout/err→`logs/`）。`discovery_agent.sh` で generate/install/uninstall/status/resume。

### 5.10 Guardrails / Status / Kill-switch
- **単一実行ロック**: `state/.lock`（原子的 mkdir・stale は pid 生存で回収）。M1 から導入し多重起動を防止。
- `state/STOP` 存在→次サイクルで安全停止。真の停止は launchd unload（M2）。
- **容量 quota**: `maxWorkspaceBytes`/`maxLogFiles` 超過＋ディスク空き下限割れ→保護停止＋通知。重ジョブ投入前にも空き再確認（M5）。
- **retention**: worker 所有の temp/log のみ明示許可で自動剪定。`runs/` 成果物は削除しない（AGENTS.md 準拠）。no-op サイクルは run dir を作らない。
- **サーキットブレーカ**: 連続失敗 N 回で PAUSED、明示復帰まで再開しない（M2）。
- **バイオセキュリティ fail-closed**: 参照/クエリ集合が `config/approved_manifest.json` の digest と不一致なら中止（M1 から参照 digest を検証）。
- `discovery_status.sh`：サイクル数・最終実行・新規累計・ネット可否・ディスク・STOP・（M2以降）ロック/PAUSED 状態。

## 6. 安全 envelope（再掲・要点）
- ネットは実行単位で既定OFF（`--allow-network` 必須）/ opt-in時も host許可制・レート制限・読取専用・範囲は承認済みJSONのみ。2026-07-15 の workspace-owner 承認後、運用設定 `enableNetwork` は有効化済み。
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
6. cursor scope binding（query digest/id不一致を破棄、同一hostの別queryもhard-fail）。
7. post-ledger障害からの同一cycle replay（入力保持・台帳非重複・最終archive）。
8. workspace quota / log retention / soft budget / timeout process-group cleanup。

## 8. ビルド順（マイルストーン）
1. **M1 骨格（オフライン・トランザクショナル）**: cycle runner＋atomic rotation＋**SQLite seen-set 台帳**＋recorder(MD再生成)＋status＋**ロック/quota/manifest**。`state/inbox` 消費で全処理配列を記録・actionable を蓄積。
2. **M2 常駐化**: launchd（**条件付き KeepAlive**）＋installer。連続実行・重なり回避・時間予算・**サーキットブレーカ(PAUSED)**・真の停止=unload。空回転回避のため最小入力源を同梱。
3. **M3 ネット回転(opt-in)**: UniProt fetcher＋envelope。範囲JSON承認フロー。
4. **M4 可視化**: dashboard generator ＋ **インタラクティブ3Dタンパク質ビューア(3Dmol.js同梱・pLDDT色分け)**。M4 時点は AlphaFold キャッシュ／「未予測」フォールバックで成立し、M5 の folding 出力で素材が充実する。
5. **M5 計算スタック**: `setup_simulation_stack.sh`＋`setup_esmfold_hf.sh`＋`sim_queue.py`（RAM予算・長さ依存入場・縮退・per-tool timeout）。MMseqs2/HMMERは候補バッチ検索、構造計算はfold→repair→relax→dockを直列化し、3Dmolへposeを渡す。ColabFold/External MSA Storeは非アクティブな設計予約。テスト5。

各マイルストーンは独立に価値があり、M1時点で「新規のみ蓄積する半永久ワーカー」として成立する。

## 9. 前提・未決
- `setup_simulation_stack.sh` の実行（多GB DL・ネット）は**ユーザー承認のもとで実施**。Claude は無断でインストール/ネットアクセスしない。
- **ColabFold は既定 OFF**。将来接続する場合も External MSA Store の precomputed a3m と完全ローカルな model parameter cache を必須とし、ローカル MSA 検索や公開 MSA サーバ問い合わせは行わない。未接続時は検証済みlocal folding backendがあれば利用し、無ければ unavailable とする。
- External MSA Store / ColabFold 接続は core M1–M5 のリリース判定対象外の後段オプションであり、現行 `enableColabFold` / `externalMsaStorePath` は予約キーである。安全な完全ローカル実行（model parameter cache を含む）を別途レビュー・検証するまで自動起動しない。
- Meta fair-esm CLI自体はCUDA前提のためApple Silicon backendにしない。Hugging Face ESMFold portを別envでrevision固定し、MPS smokeと決定性を検証済み。RAMは配列長依存なのでmax-length/RAMゲートを常に適用し、700残基超は自動投入しない。
- 3Dmol.js の同梱方法（ベンダリング）は M4 で確定。pLDDT は PDB の B-factor 列（AlphaFold/ESMFold 慣習）を既定の色分けソースとする。
