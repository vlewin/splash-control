import Foundation

/// Codable mirror of `GET /status` as served by splash 1.2.0 (`schema_version 6`).
/// Optional everywhere the server may omit a key; consumers must tolerate nils.
/// Keys this DTO does not model yet (`latency`, `frontend`, `response_store`,
/// `image_cache`, `grammar_cache`, `model_timing`, `draft_context`, `warmup`,
/// `http`, `images`, `memory_audit`, `constraint_masks`, `loop`) are ignored by
/// Codable. `recent_requests` is absent from every release to date — keep it
/// optional.
///
/// **Schema 6 renamed four keys and deleted seven.** The tray can run against an
/// adopted server of either version (it resolves a binary but adopts whatever is
/// already listening), so each rename decodes *both* spellings and the app-facing
/// name is a computed property that prefers the schema 6 one. Keys with no
/// successor were deleted rather than kept as permanently-nil fields — a field
/// that can only ever be nil is worse than no field, because it looks like data.
/// `Scripts/check_core.sh` asserts every key declared here is one the server
/// actually sends; that check is what caught this batch.
public struct StatusDTO: Codable, Equatable {
  public init() {}
  public var ready: Bool?
  public var maximumContextTokens: Int?
  public var memoryPressure: String?
  public var instance: Instance?
  public var admission: Admission?
  public var requests: Requests?
  public var scheduler: Scheduler?
  public var metrics: Metrics?
  public var metal: Metal?
  public var transport: Transport?
  public var memoryPlan: MemoryPlan?
  public var memoryActual: MemoryActual?
  public var memoryGovernor: Governor?
  public var kv: KV?
  public var state: State?
  public var cache: Cache?
  public var disk: Disk?
  public var identity: Identity?
  /// splash 1.2.1+. Absent on 1.2.0 and earlier, which is why every key is
  /// optional and why `StatsModel.weightsReleased` keeps a fallback.
  public var weights: Weights?

  public enum CodingKeys: String, CodingKey {
    case ready
    case maximumContextTokens = "maximum_context_tokens"
    case memoryPressure = "memory_pressure"
    case instance
    case admission, requests, scheduler, metrics, metal, transport
    case memoryPlan = "memory_plan"
    case memoryActual = "memory_actual"
    case memoryGovernor = "memory_governor"
    case kv, state, cache, identity, disk, weights
  }

  /// splash 1.2.1+ (tag 1.2.1, not yet on a live server here). The engine
  /// unwires backend buffers and frees the weights `idle_release_seconds`
  /// after the last request, restoring them on the next one.
  public struct Weights: Codable, Equatable {
    /// Nil when idle release is disabled (`--idle-release off`) — the server
    /// reports infinity, and there is no honest finite figure to show.
    public var idleReleaseSeconds: Double?
    /// The authoritative "weights are paged out right now". Before 1.2.1
    /// nothing published this and `StatsModel.weightsReleased` inferred it.
    public var released: Bool?
    /// How many times the weights have been restored since launch.
    public var restores: UInt64?
    public enum CodingKeys: String, CodingKey {
      case idleReleaseSeconds = "idle_release_seconds"
      case released, restores
    }
  }

  public struct Instance: Codable, Equatable {
    public var model: String?
    public var port: Int?
    public var startedAt: Double?
    public enum CodingKeys: String, CodingKey {
      case model, port
      case startedAt = "started_at"
    }
  }

  public struct MemoryPlan: Codable, Equatable {
    public struct Device: Codable, Equatable {
      public var deviceName: String?
      /// Total physical RAM. Duplicate of `budget.physical_memory_bytes`;
      /// taken from `device` because that is the hardware, not the plan.
      public var physicalMemoryBytes: UInt64?
      enum CodingKeys: String, CodingKey {
        case deviceName = "device_name"
        case physicalMemoryBytes = "physical_memory_bytes"
      }
    }
    /// splash's resolved architecture family (`Qwen3.6-35B-A3B`,
    /// `Qwen3.8-27B`) — independent of the repository id in `instance.model`.
    /// Prism Bonsai lives in repo `prism-ml/…` but resolves to family
    /// `Qwen3.8-27B`, so key per-model constants on this, not the repo id.
    public struct Model: Codable, Equatable {
      public var modelName: String?
      public var maximumContextTokens: Int?
      /// The model's fixed weight cost, in three pieces. Constant for a
      /// given model — a floor, not a time series, so it belongs on a chart
      /// as a reference line rather than a plotted series.
      public var memory: ModelMemory?
      enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case maximumContextTokens = "maximum_context_tokens"
        case memory
      }
    }

    public struct ModelMemory: Codable, Equatable {
      public var targetWeightsBytes: UInt64?
      public var draftWeightsBytes: UInt64?
      public var visionWeightsBytes: UInt64?
      enum CodingKeys: String, CodingKey {
        case targetWeightsBytes = "target_weights_bytes"
        case draftWeightsBytes = "draft_weights_bytes"
        case visionWeightsBytes = "vision_weights_bytes"
      }
      /// Sum of the weights actually loaded. Deliberately not
      /// `budget.fixed_runtime_bytes`, which additionally folds in the
      /// pipeline/overhead/kv-staging reserves and so is a different,
      /// larger number.
      public var totalWeightsBytes: UInt64? {
        let parts = [targetWeightsBytes, draftWeightsBytes, visionWeightsBytes].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
      }
    }
    public var device: Device?
    public var model: Model?
    /// The engine's hard memory ceiling (`--max-memory`). The restart guard
    /// scales its headroom threshold against this, so the meaning of
    /// "nearly out of room" is the same on a 20 GiB and a 256 GiB budget.
    public var budget: Budget?
    /// The model's **native** context window. This is the ceiling, not what
    /// the server serves: the enforced limit is the top-level
    /// `maximumContextTokens` (= min(native, memory budget, --max-context)).
    public var maximumContextTokens: Int?
    public enum CodingKeys: String, CodingKey {
      case device, model, budget
      case maximumContextTokens = "maximum_context_tokens"
    }

    public struct Budget: Codable, Equatable {
      public var hardBudgetBytes: UInt64?
      enum CodingKeys: String, CodingKey {
        case hardBudgetBytes = "hard_budget_bytes"
      }
    }
  }

  /// Why a request is not running yet. Sub-counters say *which* limit bit;
  /// `waiting` is their total.
  public struct Admission: Codable, Equatable {
    public var waiting: Int?
    public var waitingMemory: Int?
    public var waitingConcurrency: Int?
    public var suspended: Int?
    public var draining: Bool?
    public var oldestWaitMs: Double?
    public enum CodingKeys: String, CodingKey {
      case waiting, suspended, draining
      case waitingMemory = "waiting_memory"
      case waitingConcurrency = "waiting_concurrency"
      case oldestWaitMs = "oldest_wait_ms"
    }
  }

  public struct Requests: Codable, Equatable {
    // Lifetime counters of the current server process — they reset on restart.
    public var submitted: UInt64?
    public var completed: UInt64?
    public var failed: UInt64?
  }

  /// Live in-flight work, all live gauges (they drop back to 0 when idle —
  /// unlike `metrics.current_*_batch`, which are the *last* batch ever run).
  public struct Scheduler: Codable, Equatable {
    public var queued: Int?
    public var prefilling: Int?
    public var decoding: Int?
    /// Blocked on a grammar/JSON-schema mask: structured output (tool calls).
    public var waitingMask: Int?
    public var waitingPrefix: Int?
    public var waitingResources: Int?
    public var terminal: Int?
    public var decodeBatches: UInt64?
    public enum CodingKeys: String, CodingKey {
      case queued, prefilling, decoding, terminal
      case waitingMask = "waiting_mask"
      case waitingPrefix = "waiting_prefix"
      case waitingResources = "waiting_resources"
      case decodeBatches = "decode_batches"
    }
  }

  public struct LatencyWindow: Codable, Equatable {
    public var p50: Double?
    public var p95: Double?
    public var samples: Int?
  }

  public struct Batch: Codable, Equatable {
    public var valid: Bool?
    public var width: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var wallMs: Double?
    public var tokensPerSecond: Double?
    /// Speculative decoding: how many tokens the drafter proposed for this
    /// batch, and how many were accepted. The ratio is the only visible
    /// cause of the per-batch rate spread — a batch that lands its whole
    /// draft emits far more tokens for the same wall time.
    public var draftedTokens: Int?
    public var acceptedDraftTokens: Int?
    public enum CodingKeys: String, CodingKey {
      case valid, width
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
      case wallMs = "wall_ms"
      case tokensPerSecond = "tokens_per_second"
      case draftedTokens = "drafted_tokens"
      case acceptedDraftTokens = "accepted_draft_tokens"
    }
  }

  public struct Metrics: Codable, Equatable {
    public init() {}
    public var ttftMs: LatencyWindow?
    public var itlMs: LatencyWindow?
    public var prefillInputTokens: UInt64?
    public var prefillWallMs: Double?
    public var prefillTokensPerSecond: Double?
    public var decodeOutputTokens: UInt64?
    public var decodeWallMs: Double?
    public var decodeTokensPerSecond: Double?
    public var draftAcceptanceRate: Double?
    public var draftedTokens: UInt64?
    public var acceptedDraftTokens: UInt64?
    public var capacityFailures: UInt64?
    public var metalFailures: UInt64?
    public var currentPrefillBatch: Batch?
    public var currentDecodeBatch: Batch?
    public enum CodingKeys: String, CodingKey {
      case ttftMs = "ttft_ms"
      case itlMs = "itl_ms"
      case prefillInputTokens = "prefill_input_tokens"
      case prefillWallMs = "prefill_wall_ms"
      case prefillTokensPerSecond = "prefill_tokens_per_second"
      case decodeOutputTokens = "decode_output_tokens"
      case decodeWallMs = "decode_wall_ms"
      case decodeTokensPerSecond = "decode_tokens_per_second"
      case draftAcceptanceRate = "draft_acceptance_rate"
      case draftedTokens = "drafted_tokens"
      case acceptedDraftTokens = "accepted_draft_tokens"
      case capacityFailures = "capacity_failures"
      case metalFailures = "metal_failures"
      case currentPrefillBatch = "current_prefill_batch"
      case currentDecodeBatch = "current_decode_batch"
    }
  }

  public struct Metal: Codable, Equatable {
    public var healthy: Bool?
    public var failureReason: String?
    public enum CodingKeys: String, CodingKey {
      case healthy
      case failureReason = "failure_reason"
    }
  }

  public struct Transport: Codable, Equatable {
    public var ready: Bool?
    public var pending: Int?
    public var recovering: Bool?
    public var restarts: Int?
    /// Server is serving its last snapshot instead of a fresh one: heavy GPU
    /// work blocks the refresh thread. Stale, not dead.
    public var statusStale: Bool?
    public var statusAgeMs: Double?
    public enum CodingKeys: String, CodingKey {
      case ready, pending, recovering, restarts
      case statusStale = "status_stale"
      case statusAgeMs = "status_age_ms"
    }
  }

  public struct MemoryActual: Codable, Equatable {
    public var currentBytes: UInt64?
    /// schema 6 `allocated_bytes`
    public var allocatedBytes: UInt64?
    /// schema 5 `dense_bytes`; removed in schema 6
    public var legacyDenseBytes: UInt64?
    public var peakBytes: UInt64?
    public enum CodingKeys: String, CodingKey {
      case currentBytes = "current_bytes"
      case allocatedBytes = "allocated_bytes"
      case legacyDenseBytes = "dense_bytes"
      case peakBytes = "peak_bytes"
    }
    public var denseBytes: UInt64? { allocatedBytes ?? legacyDenseBytes }
  }

  public struct Governor: Codable, Equatable {
    public var limitBytes: UInt64?
    public var headroomBytes: UInt64?
    public var hostAvailableBytes: UInt64?
    public var hostHeadroomBytes: UInt64?
    /// False when the host probe failed, in which case the host figures
    /// above are meaningless and must not be used to derive anything.
    public var hostMeasurementValid: Bool?
    public var deniedReservations: UInt64?
    public var growthAllowed: Bool?
    public var systemPressure: String?
    /// schema 6 `charged_bytes`
    public var chargedBytes: UInt64?
    /// schema 5 `observed_resident_bytes`; removed in schema 6
    public var legacyObservedResidentBytes: UInt64?
    public enum CodingKeys: String, CodingKey {
      case limitBytes = "limit_bytes"
      case headroomBytes = "headroom_bytes"
      case hostAvailableBytes = "host_available_bytes"
      case hostHeadroomBytes = "host_headroom_bytes"
      case hostMeasurementValid = "host_measurement_valid"
      case deniedReservations = "denied_reservations"
      case growthAllowed = "growth_allowed"
      case systemPressure = "system_pressure"
      case chargedBytes = "charged_bytes"
      case legacyObservedResidentBytes = "observed_resident_bytes"
    }
    /// What the governor counts against its budget, in either schema.
    public var observedResidentBytes: UInt64? { chargedBytes ?? legacyObservedResidentBytes }
  }

  /// Schema 6 replaced the placement-sparse KV buffers with ordinary shared
  /// extents reached through GPU-address page tables, so this section was
  /// rewritten wholesale: `blocks`, `pages_total`, `pages_free_resident`,
  /// `map_wait_*` and `unmap_*` no longer exist, `resident_backing_bytes`
  /// became `allocated_bytes`, and `pages_resident` became `pages_allocated`.
  /// The old map/unmap counters were BUG-1's only diagnostic — the mechanism
  /// they measured is gone, so that hypothesis can no longer be tested here.
  public struct KV: Codable, Equatable {
    public var blockTokens: Int?
    public var pagesActive: Int?
    public var pagesCache: Int?
    public var pagesFree: Int?
    /// schema 6 `allocated_bytes`
    public var allocatedBytes: UInt64?
    /// schema 5 `resident_backing_bytes`; removed in schema 6
    public var legacyResidentBackingBytes: UInt64?
    /// schema 6 `pages_allocated`
    public var pagesAllocated: Int?
    /// schema 5 `pages_resident`; removed in schema 6
    public var legacyPagesResident: Int?
    /// KV memory the engine could hand back. Successor to schema 5's
    /// `reclaimable_backing_bytes`; zero means the KV cache is clean, which
    /// is how BUG-11 proved the problem lived in `state`, not KV.
    public var reclaimableBytes: UInt64?
    public enum CodingKeys: String, CodingKey {
      case blockTokens = "block_tokens"
      case pagesActive = "pages_active"
      case pagesCache = "pages_cache"
      case pagesFree = "pages_free"
      case allocatedBytes = "allocated_bytes"
      case legacyResidentBackingBytes = "resident_backing_bytes"
      case pagesAllocated = "pages_allocated"
      case legacyPagesResident = "pages_resident"
      case reclaimableBytes = "reclaimable_bytes"
    }
    /// Backing memory the engine holds for KV, in either schema.
    public var residentBackingBytes: UInt64? { allocatedBytes ?? legacyResidentBackingBytes }
    /// KV pages the engine has allocated, in either schema.
    public var pagesResident: Int? { pagesAllocated ?? legacyPagesResident }
  }

  public struct Identity: Codable, Equatable {
    public struct Cache: Codable, Equatable {
      public var buildId: String?
      public var dtype: String?
      enum CodingKeys: String, CodingKey {
        case buildId = "build_id"
        case dtype
      }
    }
    public var cache: Cache?
  }

  /// Schema 6 dropped `hits` / `misses` and renamed `resident_bytes` to
  /// `allocated_bytes`. Note the semantic shift: allocated is a floor that
  /// stays put when the cache empties, resident tracked live content — so
  /// "how much does the cache hold" wants `bytes`, not either of these.
  public struct State: Codable, Equatable {
    public var entries: Int?
    public var bytes: UInt64?
    /// schema 6 `allocated_bytes`
    public var allocatedBytes: UInt64?
    /// schema 5 `resident_bytes`; removed in schema 6
    public var legacyResidentBytes: UInt64?
    public var evictions: Int?
    public enum CodingKeys: String, CodingKey {
      case entries, bytes, evictions
      case allocatedBytes = "allocated_bytes"
      case legacyResidentBytes = "resident_bytes"
    }
    /// State-cache memory held, in either schema.
    public var residentBytes: UInt64? { allocatedBytes ?? legacyResidentBytes }
  }

  /// The `--max-cache-disk` SSD tier. Every key optional so an older release
  /// decodes this as nil rather than failing.
  public struct Disk: Codable, Equatable {
    /// The quota itself — the denominator, so saturation is meaningful.
    public var capacityBytes: UInt64?
    public var usedBytes: UInt64?
    public var kvBytes: UInt64?
    public var writtenBytes: UInt64?
    public var readBytes: UInt64?
    /// Pages moved to the tier, and how many it *refused* — that difference
    /// is what separates "the tier was never needed" from "the tier is
    /// full", which a used-bytes figure alone cannot show.
    public var kvDemotions: Int?
    public var kvDemotionsRefused: Int?
    public var kvRestoreFailures: Int?
    public enum CodingKeys: String, CodingKey {
      case capacityBytes = "capacity_bytes"
      case usedBytes = "used_bytes"
      case kvBytes = "kv_bytes"
      case writtenBytes = "written_bytes"
      case readBytes = "read_bytes"
      case kvDemotions = "kv_demotions"
      case kvDemotionsRefused = "kv_demotions_refused"
      case kvRestoreFailures = "kv_restore_failures"
    }

    /// Fraction of the quota in use. `used_bytes` is the tier's **whole**
    /// quota use — the quota is shared by states and KV, so it already
    /// includes the KV that `kv_bytes` reports. `kv_bytes` is a *share* of
    /// `used_bytes`, never a complement: adding the two double-counts the
    /// KV and is how the SSD tile once read 132.7% of a 16 GiB quota the
    /// server never exceeded. Nil when the quota is unknown, and nil when
    /// the tier is disabled (`capacity_bytes == 0`), so a disabled tier
    /// never reads as 0% of something.
    public var saturation: Double? {
      guard let capacity = capacityBytes, capacity > 0,
        let used = usedBytes
      else { return nil }
      return Double(used) / Double(capacity)
    }
  }

  /// Schema 6 dropped `lookups` and normalised the publication counters; the
  /// hit-rate denominator is no longer published, so the UI must not print a
  /// lookup count it can no longer obtain (see `DashboardView`'s cache tile).
  public struct Cache: Codable, Equatable {
    public var hits: Int?
    public var hitRate: Double?
    public var reusedTokens: UInt64?
    public enum CodingKeys: String, CodingKey {
      case hits
      case hitRate = "hit_rate"
      case reusedTokens = "reused_tokens"
    }
  }
}
