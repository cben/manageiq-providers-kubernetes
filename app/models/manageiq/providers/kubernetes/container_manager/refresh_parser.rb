require 'shellwords'

module ManageIQ::Providers::Kubernetes
  class ContainerManager::RefreshParser
    include Vmdb::Logging
    include ContainerManager::EntitiesMapping
    include ContainerManager::InventoryCollections

    def self.ems_inv_to_hashes(inventory, options = Config::Options.new)
      new(options).ems_inv_to_hashes(inventory, options)
    end

    def self.ems_inv_to_inv_collections(ems, inventory, options = Config::Options.new)
      new(options).ems_inv_to_inv_collections(ems, inventory, options)
    end

    def initialize(options = Config::Options.new)
      @options = options

      @data = {}
      @data_index = {}
      @label_tag_mapping = ContainerLabelTagMapping.cache
    end

    def ems_inv_to_hashes(inventory, _options = Config::Options.new)
      get_additional_attributes(inventory)
      get_nodes(inventory)
      get_namespaces(inventory)
      get_resource_quotas(inventory)
      get_limit_ranges(inventory)
      get_replication_controllers(inventory)
      get_persistent_volume_claims(inventory)
      get_persistent_volumes(inventory)
      get_pods(inventory)
      get_endpoints(inventory)
      get_services(inventory)
      get_component_statuses(inventory)
      EmsRefresh.log_inv_debug_trace(@data, "data:")
      @data
    end

    def ems_inv_to_inv_collections(ems, inventory, _options = Config::Options.new)
      initialize_inventory_collections(ems)
      get_nodes_graph(inventory)
      get_namespaces_graph(inventory)
      get_resource_quotas_graph(inventory)
      get_limit_ranges_graph(inventory)
      get_replication_controllers_graph(inventory)
      get_persistent_volume_claims_graph(inventory)
      get_persistent_volumes_graph(inventory)
      get_pods_graph(inventory)
      get_services_graph(inventory)
      get_component_statuses_graph(inventory)
      # The following use images resulting from parsing pods, so must be called after.
      # TODO: openshift images parsing will have to plug before this.
      get_container_images_graph(inventory)
      get_container_image_registries_graph(inventory)

      @inv_collections.values
    end

    def get_nodes(inventory)
      key = path_for_entity("node")
      process_collection(inventory["node"], key) { |n| parse_node(n) }
      @data[key].each do |cn|
        cn[:additional_attributes] = @data_index.fetch_path(:additional_attributes, :by_node, cn[:name])
        @data_index.store_path(key, :by_name, cn[:name], cn)
      end
    end

    def get_services(inventory)
      key = path_for_entity("service")
      process_collection(inventory["service"], key) { |s| parse_service(s) }
      @data[key].each do |se|
        se[:container_groups] = @data_index.fetch_path(
          :container_endpoints, :by_namespace_and_name, se[:namespace], se[:name],
          :container_groups
        )
        se[:project] = @data_index.fetch_path(path_for_entity("namespace"), :by_name, se[:namespace])
        @data_index.store_path(key, :by_namespace_and_name, se[:namespace], se[:name], se)
      end
    end

    def get_replication_controllers(inventory)
      key = path_for_entity("replication_controller")
      process_collection(inventory["replication_controller"],
                         key) do |rc|
        parse_replication_controllers(rc)
      end
      @data[key].each do |rc|
        rc[:project] = @data_index.fetch_path(path_for_entity("namespace"), :by_name, rc[:namespace])
        @data_index.store_path(key,
                               :by_namespace_and_name, rc[:namespace], rc[:name], rc)
      end
    end

    def get_pods(inventory)
      key = path_for_entity("pod")
      process_collection(inventory["pod"], key) { |n| parse_pod(n) }
      @data[key].each do |cg|
        node_name = cg.delete(:container_node_name)
        cg[:container_node] = node_name && @data_index.fetch_path(path_for_entity("node"), :by_name, node_name)
        cg[:project] = @data_index.fetch_path(path_for_entity("namespace"), :by_name, cg[:namespace])
        replicator_ref = cg.delete(:container_replicator_ref)
        cg[:container_replicator] = replicator_ref && @data_index.fetch_path(
          path_for_entity("replication_controller"), :by_namespace_and_name,
          replicator_ref[:namespace], replicator_ref[:name]
        )
        @data_index.store_path(key, :by_namespace_and_name,
                               cg[:namespace], cg[:name], cg)
      end
    end

    def get_endpoints(inventory)
      process_collection(inventory["endpoint"], :container_endpoints) { |n| parse_endpoint(n) }

      @data[:container_endpoints].each do |ep|
        cgs = ep.delete(:container_groups_refs).collect do |ref|
          @data_index.fetch_path(path_for_entity("pod"), :by_namespace_and_name, ref[:namespace], ref[:name])
        end
        ep[:container_groups] = cgs.compact
        @data_index.store_path(:container_endpoints, :by_namespace_and_name,
                               ep[:namespace], ep[:name], ep)
      end
    end

    def get_namespaces(inventory)
      key = path_for_entity("namespace")
      process_collection(inventory["namespace"], key) { |n| parse_namespace(n) }

      @data[key].each do |ns|
        @data_index.store_path(key, :by_name, ns[:name], ns)
      end
    end

    def get_persistent_volumes(inventory)
      key = path_for_entity("persistent_volume")
      process_collection(inventory["persistent_volume"], key) { |n| parse_persistent_volume(n) }
      @data[key].each do |pv|
        pvc_ref = pv.delete(:persistent_volume_claim_ref)
        pv[:persistent_volume_claim] = pvc_ref && @data_index.fetch_path(
                                         path_for_entity("persistent_volume_claim"),
                                         :by_namespace_and_name, pvc_ref[:namespace], pvc_ref[:name]
                                       )
        @data_index.store_path(key, :by_name, pv[:name], pv)
      end
    end

    def get_persistent_volume_claims(inventory)
      key = path_for_entity("persistent_volume_claim")
      process_collection(inventory["persistent_volume_claim"], key) { |n| parse_persistent_volume_claim(n) }
      @data[key].each do |pvc|
        @data_index.store_path(key, :by_namespace_and_name, pvc[:namespace], pvc[:name], pvc)
      end
    end

    def get_resource_quotas(inventory)
      key = path_for_entity("resource_quota")
      process_collection(inventory["resource_quota"], key) { |n| parse_quota(n) }
      @data[key].each do |q|
        q[:project] = @data_index.fetch_path(path_for_entity("namespace"), :by_name, q.delete(:namespace))
      end
    end

    def get_limit_ranges(inventory)
      key = path_for_entity("limit_range")
      process_collection(inventory["limit_range"], key) { |n| parse_range(n) }
      @data[key].each do |r|
        r[:project] = @data_index.fetch_path(path_for_entity("namespace"), :by_name, r.delete(:namespace))
      end
    end

    def get_component_statuses(inventory)
      key = path_for_entity("component_status")
      process_collection(inventory["component_status"], key) do |cs|
        parse_component_status(cs)
      end
      @data[key].each do |cs|
        @data_index.store_path(key, :by_name, cs[:name], cs)
      end
    end

    def get_additional_attributes(inventory)
      inventory["additional_attributes"] ||= {}
      process_collection(inventory["additional_attributes"], :additional_attributes) do |aa|
        parse_additional_attribute(aa)
      end

      @data[:additional_attributes].each do |aa|
        ats = @data_index.fetch_path(:additional_attributes, :by_node, aa[:node]) || []
        ats << {:name => aa[:name], :value => aa[:value], :section => "additional_attributes"}
        @data_index.store_path(:additional_attributes, :by_node, aa[:node], ats)
      end
    end

    ## InventoryObject Refresh methods

    def get_nodes_graph(inv)
      collection = @inv_collections[:container_nodes]

      inv["node"].each do |data|
        h = parse_node(data)

        h.except!(:namespace, :tags)

        _custom_attrs = h.extract!(:labels, :additional_attributes)
        children = h.extract!(:container_conditions, :computer_system)

        node = collection.build(h)

        get_node_container_conditions_graph(node, children[:container_conditions])
        get_node_computer_systems_graph(node, children[:computer_system])
      end
    end

    def get_node_container_conditions_graph(parent, hashes)
      # TODO
    end

    def get_node_computer_systems_graph(parent, hash)
      return if hash.nil?

      hash[:managed_entity] = parent
      children = hash.extract!(:hardware, :operating_system)

      computer_system = @inv_collections[:computer_systems].build(hash)

      get_node_computer_system_hardware_graph(computer_system, children[:hardware])
      get_node_computer_system_operating_system_graph(computer_system, children[:operating_system])
    end

    def get_node_computer_system_hardware_graph(parent, hash)
      return if hash.nil?
      hash[:computer_system] = parent
      @inv_collections[:computer_system_hardwares].build(hash)
    end

    def get_node_computer_system_operating_system_graph(parent, hash)
      return if hash.nil?
      hash[:computer_system] = parent
      @inv_collections[:computer_system_operating_systems].build(hash)
    end

    def get_namespaces_graph(inv)
      collection = @inv_collections[:container_projects]

      inv["namespace"].each do |ns|
        h = parse_namespace(ns)

        h.except!(:tags)

        _custom_attrs = h.extract!(:labels)

        collection.build(h)
      end
    end

    def get_resource_quotas_graph(inv)
      collection = @inv_collections[:container_quotas]

      inv["resource_quota"].each do |quota|
        h = parse_quota(quota)

        h[:container_project] = lazy_find_project(h.delete(:project))

        items = h.delete(:container_quota_items)
        get_container_quota_items_graph(h, items)

        collection.build(h)
      end
    end

    def get_container_quota_items_graph(parent, hashes)
      container_quota = @inv_collections[:container_quotas].lazy_find(parent[:ems_ref])
      hashes.each do |hash|
        hash[:container_quota] = container_quota
        @inv_collections[:container_quota_items].build(hash)
      end
    end

    def get_limit_ranges_graph(inv)
      collection = @inv_collections[:container_limits]

      inv["limit_range"].each do |data|
        h = parse_range(data)

        h[:container_project] = lazy_find_project(h.delete(:project))
        items = h.delete(:container_limit_items)

        limit = collection.build(h)

        get_limit_range_items_graph(limit, items)
      end
    end

    def get_limit_range_items_graph(parent, hashes)
      collection = @inv_collections[:container_limit_items]
      hashes.each do |hash|
        hash[:container_limit] = parent
        collection.build(hash)
      end
    end

    def get_replication_controllers_graph(inv)
      collection = @inv_collections[:container_replicators]

      inv["replication_controller"].each do |rc|
        h = parse_replication_controllers(rc)

        h.except!(:namespace, :tags)

        h[:container_project] = lazy_find_project(h.delete(:project))
        _custom_attrs = h.extract!(:labels, :selector_parts)

        collection.build(h)
      end
    end

    def get_persistent_volume_claims_graph(inv)
      collection = @inv_collections[:persistent_volume_claims]

      inv["persistent_volume_claim"].each do |pvc|
        h = parse_persistent_volume_claim(pvc)

        h.except!(:namespace)

        collection.build(h)
      end
    end

    def get_persistent_volumes_graph(inv)
      collection = @inv_collections[:persistent_volumes]

      inv["persistent_volume"].each do |pv|
        h = parse_persistent_volume(pv)

        h.except!(:namespace)

        collection.build(h)
      end
    end

    def get_pods_graph(inv)
      collection = @inv_collections[:container_groups]

      inv["pod"].each do |pod|
        h = parse_pod(pod)

        h.except!(:tags, :namespace)

        h[:container_project] = lazy_find_project(h.delete(:project))

        _build_pod_name = h.delete(:build_pod_name)
        _custom_attrs   = h.extract!(:labels, :node_selector_parts)
        children        = h.extract!(:container_definitions, :containers, :container_conditions, :container_volumes)

        container_group = collection.build(h)

        get_container_definitions_graph(container_group, children[:container_definitions])
      end
    end

    def get_container_definitions_graph(parent, hashes)
      collection = @inv_collections[:container_definitions]
      hashes.each do |h|
        h[:container_group] = parent
        children = h.extract!(:container_port_configs, :container_env_vars, :security_context, :container)

        container_definition = collection.build(h)

        get_container_port_configs_graph(container_definition, children[:container_port_configs])
        get_container_env_vars_graph(container_definition, children[:container_env_vars])
        get_container_security_context_graph(container_definition, children[:security_context]) if children[:security_context]
        get_container_graph(container_definition, children[:container]) if children[:container]
      end
    end

    def get_container_port_configs_graph(parent, hashes)
      collection = @inv_collections[:container_port_configs]
      hashes.each do |h|
        h[:container_definition] = parent
        collection.build(h)
      end
    end

    def get_container_env_vars_graph(parent, hashes)
      collection = @inv_collections[:container_env_vars]
      hashes.each do |h|
        h[:container_definition] = parent
        collection.build(h)
      end
    end

    def get_container_security_context_graph(parent, h)
      collection = @inv_collections[:security_contexts]
      h[:resource] = parent
      collection.build(h)
    end

    def get_container_graph(parent, h)
      collection = @inv_collections[:containers]

      h[:container_definition] = parent
      h[:container_image] = lazy_find_image(h[:container_image])

      collection.build(h)
    end

    def get_services_graph(inv)
      collection = @inv_collections[:container_services]

      inv["service"].each do |service|
        h = parse_service(service)

        h.except!(:tags, :namespace)

        h[:container_project] = lazy_find_project(h.delete(:project))

        _custom_attrs = h.extract!(:labels, :selector_parts)
        _children     = h.extract!(:container_service_port_configs)

        _container_image_registry = h.delete(:container_image_registry)
        _container_groups         = h.delete(:container_groups)

        collection.build(h)
      end
    end

    def get_component_statuses_graph(inv)
      collection = @inv_collections[:container_component_statuses]

      inv["component_status"].each do |cs|
        h = parse_component_status(cs)
        collection.build(h)
      end
    end

    def get_container_image_registries_graph(inv)
      collection = @inv_collections[:container_image_registries]
      # Resulting from previously parsed images
      registries = @data_index.fetch_path(:container_image_registry, :by_host_and_port) || []
      registries.each do |_host_port, ir|
        collection.build(ir)
      end
    end

    def get_container_images_graph(inv)
      collection = @inv_collections[:container_images]
      # Resulting from previously parsed images
      images = @data_index.fetch_path(:container_image, :by_digest) || []
      images.each do |_digest, im|
        im = im.merge(:container_image_registry => lazy_find_image_registry(im[:container_image_registry]))
        _custom_attrs = im.extract!(:labels, :docker_labels)
        collection.build(im)
      end
    end

    def process_collection(collection, key, &block)
      @data[key] ||= []
      collection.each { |item| process_collection_item(item, key, &block) }
    end

    def process_collection_item(item, key)
      @data[key] ||= []

      new_result = yield(item)

      @data[key] << new_result
      new_result
    end

    def map_labels(model_name, labels)
      ContainerLabelTagMapping.map_labels(@label_tag_mapping, model_name, labels)
    end

    def find_host_by_provider_id(provider_id)
      scheme, instance_uri = provider_id.split("://", 2)
      prov, name_field = scheme_to_provider_mapping[scheme]
      instance_id = instance_uri.split('/').last

      prov::Vm.find_by(name_field => instance_id) if !prov.nil? && !instance_id.blank?
    end

    def scheme_to_provider_mapping
      @scheme_to_provider_mapping ||= begin
        {
          'gce'       => ['ManageIQ::Providers::Google::CloudManager'.safe_constantize, :name],
          'aws'       => ['ManageIQ::Providers::Amazon::CloudManager'.safe_constantize, :uid_ems],
          'openstack' => ['ManageIQ::Providers::Openstack::CloudManager'.safe_constantize, :uid_ems]
        }.reject { |_key, (provider, _name)| provider.nil? }
      end
    end

    def find_host_by_bios_uuid(new_result)
      identity_system = new_result[:identity_system].try(:downcase)
      Vm.find_by(:uid_ems => identity_system,
                 :type    => uuid_provider_types) if identity_system
    end

    def uuid_provider_types
      @uuid_provider_types ||= begin
        ['ManageIQ::Providers::Redhat::InfraManager::Vm',
         'ManageIQ::Providers::Openstack::CloudManager::Vm',
         'ManageIQ::Providers::Vmware::InfraManager::Vm'].map(&:safe_constantize).compact.map(&:name)
      end
    end

    def cross_link_node(new_result)
      # Establish a relationship between this node and the vm it is on (if it is in the system)
      host_instance = nil
      unless new_result[:identity_infra].blank?
        host_instance = find_host_by_provider_id(new_result[:identity_infra])
      end
      unless host_instance
        host_instance = find_host_by_bios_uuid(new_result)
      end

      new_result[:lives_on_id] = host_instance.try(:id)
      new_result[:lives_on_type] = host_instance.try(:type)
    end

    def parse_additional_attribute(attribute)
      # Assuming keys are in format "node/<hostname.example.com/key"
      if attribute[0] && attribute[0].split("/").count == 3
        { attribute[0].split("/").first.to_sym => attribute[0].split("/").second,
          :name                                => attribute[0].split("/").last,
          :value                               => attribute[1],
          :section                             => "additional_attributes"}
      else
        {}
      end
    end

    def parse_node(node)
      new_result = parse_base_item(node)

      labels = parse_labels(node)
      new_result.merge!(
        :type           => 'ManageIQ::Providers::Kubernetes::ContainerManager::ContainerNode',
        :identity_infra => node.spec.providerID,
        :labels         => labels,
        :tags           => map_labels('ContainerNode', labels),
        :lives_on_id    => nil,
        :lives_on_type  => nil
      )

      node_info = node.status.try(:nodeInfo)
      if node_info
        new_result.merge!(
          :identity_machine           => node_info.machineID,
          :identity_system            => node_info.systemUUID,
          :container_runtime_version  => node_info.containerRuntimeVersion,
          :kubernetes_proxy_version   => node_info.kubeProxyVersion,
          :kubernetes_kubelet_version => node_info.kubeletVersion
        )
      end

      node_memory = node.status.try(:capacity).try(:memory)
      node_memory = parse_capacity_field("Node-Memory", node_memory)
      node_memory &&= node_memory / 1.megabyte

      new_result[:computer_system] = {
        :hardware         => {
          :cpu_total_cores => node.status.try(:capacity).try(:cpu),
          :memory_mb       => node_memory
        },
        :operating_system => {
          :distribution   => node_info.try(:osImage),
          :kernel_version => node_info.try(:kernelVersion)
        }
      }

      max_container_groups = node.status.try(:capacity).try(:pods)
      new_result[:max_container_groups] = parse_capacity_field("Pods", max_container_groups)

      new_result[:container_conditions] = parse_conditions(node)
      cross_link_node(new_result)

      new_result
    end

    def parse_service(service)
      new_result = parse_base_item(service)

      if new_result[:ems_ref].nil? # Typically this happens for kubernetes services
        new_result[:ems_ref] = "#{new_result[:namespace]}_#{new_result[:name]}"
      end

      labels = parse_labels(service)
      new_result.merge!(
        # TODO: We might want to change portal_ip to clusterIP
        :portal_ip        => service.spec.clusterIP,
        :session_affinity => service.spec.sessionAffinity,
        :service_type     => service.spec.type,
        :labels           => labels,
        :tags             => map_labels('ContainerService', labels),
        :selector_parts   => parse_selector_parts(service),
      )

      ports = service.spec.ports
      new_result[:container_service_port_configs] = Array(ports).collect do |port_entry|
        pc = parse_service_port_config(port_entry, new_result[:ems_ref])
        new_result[:container_image_registry] = @data_index.fetch_path(
          :container_image_registry, :by_host_and_port, "#{new_result[:portal_ip]}:#{pc[:port]}"
        )
        pc
      end

      new_result
    end

    def parse_pod(pod)
      # pod in kubernetes is container group in manageiq
      new_result = parse_base_item(pod)

      new_result.merge!(
        :type                  => 'ManageIQ::Providers::Kubernetes::ContainerManager::ContainerGroup',
        :restart_policy        => pod.spec.restartPolicy,
        :dns_policy            => pod.spec.dnsPolicy,
        :ipaddress             => pod.status.podIP,
        :phase                 => pod.status.phase,
        :message               => pod.status.message,
        :reason                => pod.status.reason,
        :container_node_name   => pod.spec.nodeName,
        :container_definitions => [],
        :build_pod_name        => pod.metadata.try(:annotations).try("openshift.io/build.name".to_sym)
      )

      # TODO, map volumes
      # TODO, podIP
      containers_index = {}
      containers = pod.spec.containers
      unless pod.status.nil? || pod.status.containerStatuses.nil?
        pod.status.containerStatuses.each do |cn|
          containers_index[cn.name] = parse_container(cn, pod.metadata.uid)
        end
      end

      new_result[:container_definitions] = containers.collect do |container_def|
        parse_container_definition(container_def, pod.metadata.uid).merge(
          :container => containers_index[container_def.name]
        )
      end

      new_result[:container_replicator_ref] = nil
      # NOTE: what we are trying to access here is the attribute:
      #   pod.metadata.annotations.kubernetes.io/created-by
      # but 'annotations' may be nil. The weird attribute name is
      # generated by the JSON unmarshalling.
      createdby_txt = pod.metadata.annotations.try("kubernetes.io/created-by")
      unless createdby_txt.nil?
        # NOTE: the annotation content is JSON, so it needs to be parsed
        createdby = JSON.parse(createdby_txt)
        if createdby.kind_of?(Hash) && !createdby['reference'].nil?
          new_result[:container_replicator_ref] = {
            :namespace => createdby['reference']['namespace'],
            :name      => createdby['reference']['name']
          }
        end
      end

      new_result[:container_conditions] = parse_conditions(pod)

      new_result[:labels] = parse_labels(pod)
      new_result[:tags] = map_labels('ContainerGroup', new_result[:labels])
      new_result[:node_selector_parts] = parse_node_selector_parts(pod)
      new_result[:container_volumes] = parse_volumes(pod)
      new_result
    end

    def parse_endpoint(entity)
      new_result = parse_base_item(entity)
      new_result[:container_groups_refs] = []

      (entity.subsets || []).each do |subset|
        (subset.addresses || []).each do |address|
          next if address.targetRef.try(:kind) != 'Pod'
          new_result[:container_groups_refs] << address.targetRef
        end
      end

      new_result
    end

    def parse_namespace(namespace)
      new_result = parse_base_item(namespace).except(:namespace)
      new_result[:labels] = parse_labels(namespace)
      new_result[:tags] = map_labels('ContainerProject', new_result[:labels])
      new_result
    end

    def parse_persistent_volume(persistent_volume)
      new_result = parse_base_item(persistent_volume)
      new_result.merge!(parse_volume_source(persistent_volume.spec))
      new_result.merge!(
        :type                    => 'PersistentVolume',
        :capacity                => parse_resource_list(persistent_volume.spec.capacity.to_h),
        :access_modes            => persistent_volume.spec.accessModes.join(','),
        :reclaim_policy          => persistent_volume.spec.persistentVolumeReclaimPolicy,
        :status_phase            => persistent_volume.status.phase,
        :status_message          => persistent_volume.status.message,
        :status_reason           => persistent_volume.status.reason,
        :persistent_volume_claim_ref => persistent_volume.spec.claimRef,
      )

      new_result
    end

    def parse_resource_list(hash)
      hash.each_with_object({}) do |(key, val), result|
        res = parse_capacity_field(key, val)
        result[key] = res if res
      end
    end

    def parse_capacity_field(key, val)
      return nil unless val
      begin
        val.iec_60027_2_to_i
      rescue ArgumentError
        _log.warn("Capacity attribute - #{key} was in bad format - #{val}")
        nil
      end
    end

    def parse_persistent_volume_claim(claim)
      new_result = parse_base_item(claim)
      new_result.merge!(
        :desired_access_modes => claim.spec.accessModes,
        :phase                => claim.status.phase,
        :actual_access_modes  => claim.status.accessModes,
        :capacity             => parse_resource_list(claim.status.capacity.to_h),
      )

      new_result
    end

    def parse_quota(resource_quota)
      new_result = parse_base_item(resource_quota)
      new_result[:container_quota_items] = parse_quota_items resource_quota
      new_result
    end

    def parse_quota_items(resource_quota)
      new_result_h = Hash.new do |h, k|
        h[k] = {
          :resource       => k.to_s,
          :quota_desired  => nil,
          :quota_enforced => nil,
          :quota_observed => nil
        }
      end

      resource_quota.spec.hard.to_h.each do |resource_name, quota|
        new_result_h[resource_name][:quota_desired] = quota
      end

      resource_quota.status.hard.to_h.each do |resource_name, quota|
        new_result_h[resource_name][:quota_enforced] = quota
      end

      resource_quota.status.used.to_h.each do |resource_name, quota|
        new_result_h[resource_name][:quota_observed] = quota
      end

      new_result_h.values
    end

    def parse_range(limit_range)
      new_result = parse_base_item(limit_range)
      new_result[:container_limit_items] = parse_range_items limit_range
      new_result
    end

    def parse_range_items(limit_range)
      new_result_h = create_limits_matrix

      limits = limit_range.try(:spec).try(:limits) || []
      limits.each do |item|
        item[:max].to_h.each do |resource_name, limit|
          new_result_h[item[:type].to_sym][resource_name.to_sym][:max] = limit
        end

        item[:min].to_h.each do |resource_name, limit|
          new_result_h[item[:type].to_sym][resource_name.to_sym][:min] = limit
        end

        item[:default].to_h.each do |resource_name, limit|
          new_result_h[item[:type].to_sym][resource_name.to_sym][:default] = limit
        end

        item[:defaultRequest].to_h.each do |resource_name, limit|
          new_result_h[item[:type].to_sym][resource_name.to_sym][:default_request] = limit
        end

        item[:maxLimitRequestRatio].to_h.each do |resource_name, limit|
          new_result_h[item[:type].to_sym][resource_name.to_sym][:max_limit_request_ratio] = limit
        end
      end
      new_result_h.values.collect(&:values).flatten
    end

    def create_limits_matrix
      # example: h[:pod][:cpu][:max] = 8
      Hash.new do |h, item_type|
        h[item_type] = Hash.new do |j, resource|
          j[resource] = {
            :item_type               => item_type.to_s,
            :resource                => resource.to_s,
            :max                     => nil,
            :min                     => nil,
            :default                 => nil,
            :default_request         => nil,
            :max_limit_request_ratio => nil
          }
        end
      end
    end

    def parse_replication_controllers(container_replicator)
      new_result = parse_base_item(container_replicator)

      labels = parse_labels(container_replicator)
      # TODO: parse template
      new_result.merge!(
        :replicas         => container_replicator.spec.replicas,
        :current_replicas => container_replicator.status.replicas,
        :labels           => labels,
        :tags             => map_labels('ContainerReplicator', labels),
        :selector_parts   => parse_selector_parts(container_replicator)
      )
      new_result
    end

    def parse_component_status(container_component_status)
      new_result = {}

      # At this point components statuses use only one condition.
      # In the case of a future change, this will need to be modified accordingly.
      component_condition = container_component_status.conditions.first

      new_result.merge!(
        :name      => container_component_status.metadata.name,
        :condition => component_condition.type,
        :status    => component_condition.status,
        :message   => component_condition.message,
        # workaround for handling Kubernetes issue: "nil" string is returned in component status error
        # https://github.com/kubernetes/kubernetes/issues/16721
        :error     => (component_condition.error unless component_condition.error == "nil")
      )

      new_result
    end

    def parse_labels(entity)
      parse_identifying_attributes(entity.metadata.labels, 'labels')
    end

    def parse_selector_parts(entity)
      parse_identifying_attributes(entity.spec.selector, 'selectors')
    end

    def parse_node_selector_parts(entity)
      parse_identifying_attributes(entity.spec.nodeSelector, 'node_selectors')
    end

    def parse_identifying_attributes(attributes, section, source = "kubernetes")
      result = []
      return result if attributes.nil?
      attributes.to_h.each do |key, value|
        custom_attr = {
          :section => section,
          :name    => key.to_s,
          :value   => value,
          :source  => source
        }
        result << custom_attr
      end
      result
    end

    def parse_conditions(entity)
      conditions = entity.status.try(:conditions)
      conditions.to_a.collect do |condition|
        {
          :name                 => condition.type,
          :status               => condition.status,
          :last_heartbeat_time  => condition.lastHeartbeatTime,
          :last_transition_time => condition.lastTransitionTime,
          :reason               => condition.reason,
          :message              => condition.message
        }
      end
    end

    def parse_container_definition(container_def, pod_id)
      new_result = {
        :ems_ref           => "#{pod_id}_#{container_def.name}_#{container_def.image}",
        :name              => container_def.name,
        :image             => container_def.image,
        :image_pull_policy => container_def.imagePullPolicy,
        :command           => container_def.command ? Shellwords.join(container_def.command) : nil,
        :memory            => container_def.memory,
        # https://github.com/GoogleCloudPlatform/kubernetes/blob/0b801a91b15591e2e6e156cf714bfb866807bf30/pkg/api/v1beta3/types.go#L815
        :cpu_cores         => container_def.cpu.to_f / 1000,
        :capabilities_add  => container_def.securityContext.try(:capabilities).try(:add).to_a.join(','),
        :capabilities_drop => container_def.securityContext.try(:capabilities).try(:drop).to_a.join(','),
        :privileged        => container_def.securityContext.try(:privileged),
        :run_as_user       => container_def.securityContext.try(:runAsUser),
        :run_as_non_root   => container_def.securityContext.try(:runAsNonRoot),
        :security_context  => parse_security_context(container_def.securityContext)
      }
      ports = container_def.ports
      new_result[:container_port_configs] = Array(ports).collect do |port_entry|
        parse_container_port_config(port_entry, pod_id, container_def.name)
      end
      env = container_def.env
      new_result[:container_env_vars] = Array(env).collect do |env_var|
        parse_container_env_var(env_var)
      end

      new_result
    end

    def parse_container(container, pod_id)
      h = {
        :type            => 'ManageIQ::Providers::Kubernetes::ContainerManager::Container',
        :ems_ref         => "#{pod_id}_#{container.name}_#{container.image}",
        :name            => container.name,
        :restart_count   => container.restartCount,
        :backing_ref     => container.containerID,
        :container_image => parse_container_image(container.image, container.imageID)
      }
      state_attributes = parse_container_state container.lastState
      state_attributes.each { |key, val| h[key.to_s.prepend('last_').to_sym] = val } if state_attributes
      h.merge!(parse_container_state(container.state))
    end

    def parse_container_state(state_hash)
      return {} if state_hash.to_h.empty?
      res = {}
      # state_hash key is the state and value are attributes e.g 'running': {...}
      (state, state_info), = state_hash.to_h.to_a
      res[:state] = state
      %w(reason started_at finished_at exit_code signal message).each do |attr|
        res[attr.to_sym] = state_info[attr.camelize(:lower)]
      end
      res
    end

    def parse_container_image(image, imageID)
      container_image, container_image_registry = parse_image_name(image, imageID)
      host_port = nil

      unless container_image_registry.nil?
        host_port = "#{container_image_registry[:host]}:#{container_image_registry[:port]}"

        stored_container_image_registry = @data_index.fetch_path(
          :container_image_registry, :by_host_and_port,  host_port)
        if stored_container_image_registry.nil?
          @data_index.store_path(
            :container_image_registry, :by_host_and_port, host_port, container_image_registry)
          process_collection_item(container_image_registry, :container_image_registries) { |r| r }
          stored_container_image_registry = container_image_registry
        end
      end

      # if a digest exists then it is more identifiying than the image name/repo/tag
      # as one image might have many names/repos/tags.
      container_image_identity = container_image[:digest] || container_image[:image_ref]
      stored_container_image = @data_index.fetch_path(
        :container_image, :by_digest, container_image_identity)

      if stored_container_image.nil?
        @data_index.store_path(
          :container_image, :by_digest,
          container_image_identity, container_image
        )
        process_collection_item(container_image, :container_images) { |img| img }
        stored_container_image = container_image
      end

      stored_container_image[:container_image_registry] = stored_container_image_registry
      stored_container_image
    end

    def parse_container_port_config(port_config, pod_id, container_name)
      {
        :ems_ref   => "#{pod_id}_#{container_name}_#{port_config.containerPort}_#{port_config.hostPort}_#{port_config.protocol}",
        :port      => port_config.containerPort,
        :host_port => port_config.hostPort,
        :protocol  => port_config.protocol,
        :name      => port_config.name
      }
    end

    def parse_service_port_config(port_config, service_id)
      {
        :ems_ref     => "#{service_id}_#{port_config.port}_#{port_config.targetPort}",
        :name        => port_config.name,
        :protocol    => port_config.protocol,
        :port        => port_config.port,
        :target_port => (port_config.targetPort unless port_config.targetPort == 0),
        :node_port   => (port_config.nodePort unless port_config.nodePort == 0)
      }
    end

    def parse_container_env_var(env_var)
      {
        :name       => env_var.name,
        :value      => env_var.value,
        :field_path => env_var.valueFrom.try(:fieldRef).try(:fieldPath)
      }
    end

    private

    def parse_base_item(item)
      {
        :ems_ref          => item.metadata.uid,
        :name             => item.metadata.name,
        # namespace is overriden in more_core_extensions and hence needs
        # a non method access
        :namespace        => item.metadata["table"][:namespace],
        :ems_created_on   => item.metadata.creationTimestamp,
        :resource_version => item.metadata.resourceVersion
      }
    end

    def parse_image_name(image, image_ref)
      # parsing using same logic as in docker
      # https://github.com/docker/docker/blob/348f6529b71502b561aa493e250fd5be248da0d5/reference/reference.go#L174
      docker_pullable_re = %r{
        \A
          (?<protocol>#{ContainerImage::DOCKER_PULLABLE_PREFIX})?
          (?:(?:
            (?<host>([^\.:/]+\.)+[^\.:/]+)|
            (?:(?<host2>[^:/]+)(?::(?<port>\d+)))|
            (?<localhost>localhost)
          )/)?
          (?<name>(?:[^:/@]+/)*[^/:@]+)
          (?::(?<tag>[^:/@]+))?
          (?:\@(?<digest>.+))?
        \z
      }x
      docker_daemon_re = %r{
        \A
          (?<protocol>#{ContainerImage::DOCKER_IMAGE_PREFIX})?
            (?<digest>(sha256:)?.+)?
        \z
      }x
      image_parts = docker_pullable_re.match(image)
      image_ref_parts = docker_pullable_re.match(image_ref) || docker_daemon_re.match(image_ref)

      if image_ref.start_with?(ContainerImage::DOCKER_PULLABLE_PREFIX)
        hostname = image_ref_parts[:host] || image_ref_parts[:host2]
        port = image_ref_parts[:port]
        digest = image_ref_parts[:digest]
      else
        hostname = image_parts[:host] || image_parts[:host2] || image_parts[:localhost]
        port = image_parts[:port]
        digest = image_parts[:digest] || image_ref_parts.try(:[], :digest)
        registry = ((port.present? ? "#{hostname}:#{port}/" : "#{hostname}/") if hostname.present?)
        image_ref = "%{prefix}%{registry}%{name}%{digest}" % {
          :prefix   => ContainerImage::DOCKER_IMAGE_PREFIX,
          :registry => registry,
          :name     => image_parts[:name],
          :digest   => ("@#{digest}" if !digest.blank?),
        }
      end

      [
        {
          :name      => image_parts[:name],
          :tag       => image_parts[:tag],
          :digest    => digest,
          :image_ref => image_ref,
        },
        hostname && {
          :name => hostname,
          :host => hostname,
          :port => image_parts[:port],
        },
      ]
    end

    def parse_security_context(security_context)
      return if security_context.nil?
      {
        :se_linux_level => security_context.seLinuxOptions.try(:level),
        :se_linux_user  => security_context.seLinuxOptions.try(:user),
        :se_linux_role  => security_context.seLinuxOptions.try(:role),
        :se_linux_type  => security_context.seLinuxOptions.try(:type)
      }
    end

    def parse_volumes(pod)
      pod.spec.volumes.to_a.collect do |volume|
        {
          :type                    => 'ContainerVolume',
          :name                    => volume.name,
          :persistent_volume_claim => @data_index.fetch_path(path_for_entity("persistent_volume_claim"),
                                                             :by_namespace_and_name,
                                                             pod.metadata.namespace,
                                                             volume.persistentVolumeClaim.try(:claimName))
        }.merge!(parse_volume_source(volume))
      end
    end

    def parse_volume_source(volume)
      {
        :empty_dir_medium_type   => volume.emptyDir.try(:medium),
        :gce_pd_name             => volume.gcePersistentDisk.try(:pdName),
        :git_repository          => volume.gitRepo.try(:repository),
        :git_revision            => volume.gitRepo.try(:revision),
        :nfs_server              => volume.nfs.try(:server),
        :iscsi_target_portal     => volume.iscsi.try(:targetPortal),
        :iscsi_iqn               => volume.iscsi.try(:iqn),
        :iscsi_lun               => volume.iscsi.try(:lun),
        :glusterfs_endpoint_name => volume.glusterfs.try(:endpointsName),
        :claim_name              => volume.persistentVolumeClaim.try(:claimName),
        :rbd_ceph_monitors       => volume.rbd.try(:cephMonitors).to_a.join(','),
        :rbd_image               => volume.rbd.try(:rbdImage),
        :rbd_pool                => volume.rbd.try(:rbdPool),
        :rbd_rados_user          => volume.rbd.try(:radosUser),
        :rbd_keyring             => volume.rbd.try(:keyring),
        :common_path             => [volume.hostPath.try(:path),
                                     volume.nfs.try(:path),
                                     volume.glusterfs.try(:path)].compact.first,
        :common_fs_type          => [volume.gcePersistentDisk.try(:fsType),
                                     volume.awsElasticBlockStore.try(:fsType),
                                     volume.iscsi.try(:fsType),
                                     volume.rbd.try(:fsType),
                                     volume.cinder.try(:fsType)].compact.first,
        :common_read_only        => [volume.gcePersistentDisk.try(:readOnly),
                                     volume.awsElasticBlockStore.try(:readOnly),
                                     volume.nfs.try(:readOnly),
                                     volume.iscsi.try(:readOnly),
                                     volume.glusterfs.try(:readOnly),
                                     volume.persistentVolumeClaim.try(:readOnly),
                                     volume.rbd.try(:readOnly),
                                     volume.cinder.try(:readOnly)].compact.first,
        :common_secret           => [volume.secret.try(:secretName),
                                     volume.rbd.try(:secretRef).try(:name)].compact.first,
        :common_volume_id        => [volume.awsElasticBlockStore.try(:volumeId),
                                     volume.cinder.try(:volumeId)].compact.first,
        :common_partition        => [volume.gcePersistentDisk.try(:partition),
                                     volume.awsElasticBlockStore.try(:partition)].compact.first
      }
    end

    def path_for_entity(entity)
      miq_entity(entity).tableize.to_sym
    end

    def lazy_find_project(hash)
      return if hash.nil?
      @inv_collections[:container_projects].lazy_find(hash[:ems_ref])
    end

    def lazy_find_image(hash)
      return nil if hash.nil?
      hash = hash.merge(:container_image_registry => lazy_find_image_registry(hash[:container_image_registry]))
      @inv_collections[:container_images].lazy_find(
        @inv_collections[:container_images].object_index(hash)
      )
    end

    def lazy_find_image_registry(hash)
      return nil if hash.nil?
      @inv_collections[:container_image_registries].lazy_find(
        @inv_collections[:container_image_registries].object_index(hash)
      )
    end
  end
end
