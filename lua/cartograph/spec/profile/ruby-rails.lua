-- L2 environment profile: RUBY + RAILS ([[cartograph-stdlib-profile]] P2).
-- Ruby-on-Rails app code leans hard on a KNOWN ENVIRONMENT — Ruby core/Kernel,
-- ActiveSupport, and the ActiveRecord/ActionController framework — so its
-- unresolved calls are dominated by framework method names with no project def.
-- That is exactly the shape the profile ROI law rewards (contrast the self-
-- referential zig compiler at 1.2%): a rails corpus's unresolved surface is
-- framework methods, classifiable to the `stdlib` disposition WITHOUT receiver
-- typing (they reach the no-def fallback, where prof_ext blesses a covered name).
--
-- HAND-AUTHORED (like lua-factorio; no single Ruby source tree to distill — the
-- surface spans MRI core + activesupport + activerecord + actionpack gems). The
-- eventual richer source is RBS/rbi ([[cartograph-stdlib-profile]] input adapter);
-- this reviewable module is the first cut. The loader accepts .lua alongside .mpack.
--
-- Faces: (a) the flat `free` set feeds prof_ext NOW — a bare/implicit-self call
-- whose callee is a framework method becomes stdlib-tier external (the honesty
-- refinement over generic no-def). (b) `types` (owner -> members) records the
-- logical owner per method, seeding the future node-MINTING resolution face
-- (canonical `ruby-rails::Owner#member`) — increment 2, gate-visible.
--
-- SOUNDNESS: prof_ext runs at the NO-DEF position (project resolution already
-- failed), so a name here can never shadow a real def — over-inclusion only
-- refines a disposition that was already "external/unresolved". (The minting
-- face WILL need curation; that is deferred to increment 2 by design.)

-- space-separated name list → set
local function kw(s) local t = {}; for w in s:gmatch('%S+') do t[w] = true end; return t end

-- Kernel free functions: called BARE (no receiver / implicit self at top level).
local FREE_KERNEL = kw([[
    puts print p pp require require_relative load autoload gem
    raise fail throw catch loop redo retry
    proc lambda proc! block_given? yield
    rand srand sleep exit exit! abort at_exit caller caller_locations binding
    gets format sprintf printf putc warn
    Integer Float String Array Hash Rational Complex
    freeze frozen? dup clone tap then itself
    send __send__ public_send respond_to? respond_to_missing? method methods
    instance_variable_get instance_variable_set instance_variables
    instance_of? is_a? kind_of? class superclass ancestors
    object_id equal? eql? hash inspect display
    define_method method_missing extend include prepend
    attr_accessor attr_reader attr_writer attr
    require_dependency
]])

-- The framework SURFACE, grouped by logical owner (the canonical `Owner#member`
-- seed for the minting face). Members are called as `recv.member` on a receiver
-- the profile does NOT need to type — the disposition keys on the member name.
local SURFACE = {
    -- Object / ActiveSupport universal extensions
    ['Object'] = kw([[
        present? blank? presence try try! in? deep_dup to_param to_query
        acts_like? html_safe? duplicable? instance_values with_options
        nil? empty? to_s to_str to_a to_ary to_h to_hash to_i to_int to_f
        to_sym to_proc to_json to_c to_r
    ]]),
    -- Comparable / Enumerable
    ['Enumerable'] = kw([[
        each each_with_index each_with_object each_slice each_cons each_entry
        map flat_map collect collect_concat filter_map select filter find_all
        reject find detect find_index reduce inject sum min max min_by max_by
        minmax sort sort_by group_by partition chunk chunk_while slice_when
        count size length tally count_by
        include? member? any? all? none? one? cover?
        first last take drop take_while drop_while
        zip flatten compact uniq reverse rotate sample shuffle
        to_a to_h entries lazy with_index each_pair
        pluck index_by index_with maximum minimum average
        find_each find_in_batches in_batches
    ]]),
    ['Array'] = kw([[
        push pop shift unshift append prepend concat << insert delete delete_at
        delete_if compact! flatten! uniq! sort! reverse! join pack fill
        first second third fourth fifth last dig values_at
        combination permutation product transpose assoc rassoc
    ]]),
    ['Hash'] = kw([[
        keys values fetch dig store merge merge! update reverse_merge
        each_pair each_key each_value transform_values transform_keys
        transform_values! transform_keys! slice except except! extract!
        symbolize_keys stringify_keys deep_symbolize_keys deep_merge deep_dup
        with_indifferent_access key value? has_key? has_value? key? include?
        invert compact_blank compact assoc default to_options
    ]]),
    ['String'] = kw([[
        gsub gsub! sub sub! match match? =~ scan tr tr_s delete squeeze
        split lines chars bytes codepoints each_char each_line each_byte
        strip lstrip rstrip strip! chomp chomp! chop chop!
        upcase downcase capitalize swapcase titleize titlecase
        center ljust rjust start_with? end_with? include? index rindex
        slice byteslice concat prepend insert replace
        encode encoding force_encoding encode! unpack unpack1 bytesize
        to_sym intern to_str format ord hex oct succ next
        blank? present? html_safe strip_heredoc squish truncate truncate_words
        pluralize singularize camelize underscore dasherize demodulize
        classify constantize safe_constantize tableize humanize parameterize
        first last from to
    ]]),
    ['Numeric'] = kw([[
        to_i to_f to_s to_r to_c to_d abs abs2 ceil floor round truncate
        divmod div modulo remainder fdiv pow gcd lcm bit_length digits
        times upto downto step
        even? odd? zero? nonzero? positive? negative? integer? finite? infinite?
        between? clamp coerce
        seconds minutes hours days weeks months years fortnights
        ago from_now since until megabytes gigabytes kilobytes bytes
        ordinal ordinalize
    ]]),
    -- Time / Date / ActiveSupport::TimeWithZone
    ['Time'] = kw([[
        now today current utc localtime getlocal getutc
        year month day hour min sec usec wday yday mday
        strftime iso8601 rfc3339 httpdate to_time to_date to_datetime to_i to_f
        beginning_of_day end_of_day beginning_of_week end_of_week
        beginning_of_month end_of_month beginning_of_year end_of_year
        beginning_of_hour end_of_hour beginning_of_minute
        advance change ago since in in_time_zone utc? monday? sunday?
        all_day all_week all_month all_year prev_day next_day prev_month next_month
        yesterday tomorrow midnight noon
    ]]),
    -- ActiveRecord CLASS query / relation methods (Model.<m> and relation.<m>)
    ['ActiveRecord::Relation'] = kw([[
        find find_by find_by! find_or_create_by find_or_create_by!
        find_or_initialize_by find_each find_in_batches in_batches
        where where! rewhere not or and all none unscope unscoped only
        first first! last last! second third take take! forty_two
        create create! new build first_or_create first_or_initialize
        find_sole_by sole
        count sum average minimum maximum calculate size length empty? any? many? one?
        exists? include? pluck ids pick
        order reorder limit offset group having distinct distinct_on
        joins left_joins left_outer_joins includes preload eager_load references
        select reselect merge except only extending
        update_all delete_all destroy_all update! touch_all increment_counter
        readonly lock lock! from unscope reverse_order
        to_sql explain to_a to_ary load reload cache_key
    ]]),
    -- ActiveRecord class-body MACRO DSL (declarations, called with implicit self)
    ['ActiveRecord::Base'] = kw([[
        belongs_to has_one has_many has_and_belongs_to_many
        validates validate validates_presence_of validates_uniqueness_of
        validates_length_of validates_format_of validates_inclusion_of
        validates_exclusion_of validates_numericality_of validates_associated
        validates_acceptance_of validates_confirmation_of validates_with
        validates_each
        scope default_scope
        before_save after_save around_save before_create after_create
        around_create before_update after_update around_update
        before_destroy after_destroy around_destroy
        before_validation after_validation
        after_commit after_rollback after_initialize after_find after_touch
        delegate delegate_missing_to enum serialize store store_accessor
        attribute attribute_names composed_of
        accepts_nested_attributes_for
        has_secure_password has_secure_token has_one_attached has_many_attached
        broadcasts_to broadcasts after_create_commit after_update_commit
        after_destroy_commit after_save_commit
        default_scope scope_for readonly abstract_class
        primary_key table_name inheritance_column
        counter_cache touch optimistic_locking
    ]]),
    -- ActiveRecord instance persistence
    ['ActiveRecord::Persistence'] = kw([[
        save save! update update! update_attribute update_attributes
        update_column update_columns destroy destroy! delete
        reload valid? invalid? validate errors persisted? new_record?
        destroyed? previously_new_record? changed? changes changed_attributes
        previous_changes saved_changes saved_change_to_attribute
        attribute_changed? attribute_was attribute_before_last_save
        attributes attribute_names read_attribute write_attribute
        read_attribute_before_type_cast assign_attributes attributes=
        touch increment increment! decrement decrement! toggle toggle!
        becomes becomes! transaction with_lock lock! reset_counters
        association reload_association build_association create_association
    ]]),
    -- ActionController
    ['ActionController::Base'] = kw([[
        params render render_to_string redirect_to redirect_back
        redirect_back_or_to head respond_to respond_with
        request response session cookies flash
        before_action after_action around_action append_before_action
        prepend_before_action skip_before_action skip_after_action
        rescue_from helper_method helper before_render
        send_data send_file authenticate_or_request_with_http_basic
        authenticate_with_http_basic authenticate_or_request_with_http_token
        fresh_when stale? expires_in expires_now no_store
        default_url_options url_for polymorphic_url polymorphic_path
    ]]),
    -- ActionView helpers
    ['ActionView::Helpers'] = kw([[
        link_to link_to_if link_to_unless button_to
        form_for form_with form_tag fields_for
        content_tag tag concat safe_join sanitize raw
        image_tag video_tag audio_tag image_url asset_path asset_url
        javascript_include_tag stylesheet_link_tag
        url_for path_to url_to
        number_to_currency number_to_percentage number_with_delimiter
        number_with_precision number_to_human number_to_human_size
        time_ago_in_words distance_of_time_in_words pluralize truncate
        highlight excerpt word_wrap simple_format
        t translate l localize
        render render_partial cache provide content_for yield capture
        csrf_meta_tags stylesheet_path javascript_path
    ]]),
    -- Rails singleton + logger
    ['Rails'] = kw([[
        logger env root application cache configuration version
        debug info warn error fatal unknown
    ]]),
}

-- Ruby namespaces used as `Root.member` / `Root::Nested` roots. For the prefix
-- gate only the ROOT matters (a `Root.member` call at no-def → stdlib).
local NAMESPACES = {
    'Rails', 'ActiveRecord', 'ActiveSupport', 'ActionController', 'ActionView',
    'ActiveModel', 'ActiveJob', 'ActionMailer', 'ActionCable',
    'I18n', 'Time', 'Date', 'DateTime', 'Kernel', 'Module', 'Struct', 'Comparable',
    'JSON', 'YAML', 'Marshal', 'Digest', 'SecureRandom', 'Base64', 'URI', 'Set',
    'BigDecimal', 'Logger', 'Mutex', 'Thread', 'File', 'Dir', 'IO', 'Math',
    'Regexp', 'Random', 'ObjectSpace', 'GC', 'Process', 'Signal', 'Enumerator',
}

-- CANONICAL OWNER priority (highest first): a method that appears in several
-- owners takes the FIRST one here as its canonical owner — tuned so universals →
-- Object, collections → Enumerable, AR query → Relation, persistence →
-- Persistence, class macros → ActiveRecord::Base. The owner-precise minting face
-- keys `ruby-rails::Owner#member` off this ([[cartograph-stdlib-profile]]).
local OWNER_ORDER = {
    'ActiveRecord::Base', 'ActiveRecord::Persistence', 'ActiveRecord::Relation',
    'ActionController::Base', 'ActionView::Helpers', 'Rails',
    'Object', 'Enumerable', 'Time', 'Numeric', 'String', 'Array', 'Hash',
}
-- owners whose members are class/singleton methods → emit `.` (else `#` instance).
-- The AR class-body DSL (belongs_to/validates/scope) are class macros.
local CLASS_LEVEL = { ['ActiveRecord::Base'] = true }

-- derived flat projections (built once): free (the prof_ext bless set) unions the
-- Kernel bares AND every SURFACE member name (ruby dispatch is by member name at
-- the no-def fallback); vocab = free ∪ members; nsset = namespace roots; canon =
-- member → canonical `Owner<sep>member` path for the owner-precise mint face.
local free, namespaces, nsset, vocab, types, canon = {}, {}, {}, {}, {}, {}
for n in pairs(FREE_KERNEL) do free[n] = {}; vocab[n] = true end
for owner, members in pairs(SURFACE) do
    local mt = {}
    for m in pairs(members) do
        mt[m] = {}
        free[m] = {}   -- bless the member name at the no-def disposition position
        vocab[m] = true
    end
    types[owner] = { members = mt }
end
-- canonical owner: walk OWNER_ORDER (priority), first owner containing a method wins
for _, owner in ipairs(OWNER_ORDER) do
    local members = SURFACE[owner]
    if members then
        local sep = CLASS_LEVEL[owner] and '.' or '#'
        for m in pairs(members) do
            if not canon[m] then canon[m] = owner .. sep .. m end
        end
    end
end
-- Kernel free functions (not in a SURFACE owner) canonicalize to Kernel#<m>
for m in pairs(FREE_KERNEL) do
    if not canon[m] then canon[m] = 'Kernel#' .. m end
end

-- RBS GROUND TRUTH ([[cartograph-stdlib-profile]] RBS enrichment): override the
-- hand-authored canonical owner with the RBS defining owner for CORE-owned methods
-- (ruby-core.mpack, distilled by tools/rbsdistill.lua, version-keyed + checked in →
-- deterministic). Only override methods whose hand owner is a CORE class — a Rails
-- owner (AR/ActionController/ActionView/Rails) is a framework-context choice core
-- RBS can't see, so it stands. Missing artifact → hand-authored owners (graceful).
local RAILS_OWNERS = {
    ['ActiveRecord::Base'] = true, ['ActiveRecord::Persistence'] = true,
    ['ActiveRecord::Relation'] = true, ['ActionController::Base'] = true,
    ['ActionView::Helpers'] = true, ['Rails'] = true,
}
local core = require('cartograph.spec.profile').load('ruby-core')
local sigs, sig_root
if core and core.canon then
    for m, path in pairs(canon) do
        local my_owner = path:match('^(.-)[#.]')
        if not RAILS_OWNERS[my_owner] and core.canon[m] then
            canon[m] = core.canon[m]
        end
    end
    -- nav-time enrichment ([[cartograph-stdlib-profile]]): the RBS signatures +
    -- locations ride on the profile for LSP hover/go-to-def to look up by the minted
    -- node's Owner#member path — read-side only, never baked into the graph.
    sigs = core.sigs
    sig_root = core.stamp and core.stamp.root
end
-- Rails RBS signatures (gem_rbs_collection) keyed BY MEMBER NAME — Rails' RBS
-- owners are deep internal modules, not the profile's recognizable coarse owners,
-- so hover looks these up by member (the node keeps its own owner in the id) and
-- shows the RBS owner as provenance. Locations are relative to the rails source root.
local rails_sigs = core and core.rails_sigs
local rails_root = core and core.stamp and core.stamp.rails_source
for _, ns in ipairs(NAMESPACES) do
    namespaces[#namespaces + 1] = ns
    nsset[ns] = true
    vocab[ns] = true
end

return {
    schema = 1, runtime = 'ruby-rails', lang = 'ruby', version = 'rails-7',
    stamp = 'hand-authored',
    -- mint=true: opt in to the RESOLUTION face — disposed framework calls become
    -- resolved `ruby-rails::<method>` external nodes at the stdlib tier (LSP-
    -- targetable). A disposition-only profile omits this (lua-factorio stays gate-
    -- neutral). Ruby's bare-method dispatch makes the no-def framework call the
    -- overwhelming reality, so minting the hand-curated surface is sound-at-tier.
    mint = true,
    types = types, free = free, namespaces = namespaces, nsset = nsset,
    vocab = vocab, canon = canon, sigs = sigs, sig_root = sig_root,
    rails_sigs = rails_sigs, rails_root = rails_root,
}
