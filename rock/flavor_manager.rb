module Rock
    class FlavorManager
        # The set of defined flavors
        #
        # @return [Hash<String,FlavorDefinition>]
        attr_reader :flavors
        # The package sets that are managed through flavors
        #
        # @return [Array<Autoproj::PackageSet>]
        attr_reader :package_sets
        # The current flavor
        #
        # @return [FlavorDefinition]
        attr_reader :current_flavor

        def initialize
            @flavors = Hash.new
            @package_sets = Set.new
        end

        # Test if a given flavor exists
        #
        # @param [String] flavor_name the flavor name
        def has_flavor?(flavor_name)
            flavors.has_key?(flavor_name)
        end

        # Resolves a flavor by its name
        # @param [String] flavor_name the flavor name
        # @return [FlavorDefinition] the flavor
        # @raise ArgumentError if the provided name is not the name of a
        #   registered flavor
        def flavor_by_name(flavor_name)
            if flavor_def = flavors[flavor_name]
                flavor_def
            else
                raise ArgumentError, "#{flavor_name} is not a known flavor name"
            end
        end

        # Tests if a given package is included in the specified flavor
        #
        # @param [#name,#to_str] pkg the package or its name
        # @param [String] flavor_name the name of the flavor
        def package_in_flavor?(pkg, flavor_name)
            flavor_def = flavor_by_name(flavor_name)
            if pkg.respond_to?(:name)
                pkg = pkg.name
            end

            if flavor_def.implicit?
                if Autoproj.respond_to?(:workspace) # 2.0
                    pkg_set = Autoproj.manifest.find_package_definition(pkg).package_set
                else
                    pkg_set = Autoproj.manifest.find_package(pkg).package_set
                end
                if package_sets.include?(pkg_set)
                    !flavor_def.removed?(pkg)
                else
                    flavor_def.include?(pkg)
                end
            else
                return flavor_def.include?(pkg)
            end
        end

        # Selects {current_flavor} by its name in {flavors}
        def select_current_flavor_by_name(flavor_name)
            if flv = flavors[flavor_name]
                @current_flavor = flv
            else raise ArgumentError, "#{flavor_name} is not the name of a known flavor"
            end
        end

        def find_all_flavors_by_branch(branch)
            flavors.values.find_all { |flv| flv.branch == branch }
        end

        def alias(old_name, new_name)
            flavors[new_name.to_str] = flavor_by_name(old_name)
        end

        # Create a new flavor in the set of known flavors, and register it on
        # {flavors}
        #
        # @param [String] flavor_name the name of the new flavor
        # @option options [Boolean] :implicit (nil) sets the new flavor's
        #   {FlavorDefinition#implicit?} flag
        # @return [FlavorDefinition]
        def define(flavor_name, options = Hash.new)
            options = Kernel.validate_options(options, :implicit => nil, :branch => flavor_name)

            flavor = (flavors[flavor_name] ||= FlavorDefinition.new(flavor_name, options[:branch]))
            if !options[:implicit].nil?
                flavor.implicit = options[:implicit]
            end
            flavor
        end

        # Declares that the package definitions created by the given block are
        # part of the listed flavors
        def in_flavor(*flavors, &block)
            if flavors.last.kind_of?(Hash)
                options = flavors.pop
                options = Kernel.validate_options options, :strict => false
            else
                options = Hash.new
            end

            flavor = current_flavor

            current_packages = Autoproj.manifest.packages.keys
            InFlavorContext.new(flavor.name, flavors, options[:strict]).
                instance_eval(&block)

            new_packages = Autoproj.manifest.packages.keys - current_packages
            add_packages_to_flavors Autoproj.current_package_set, flavors => new_packages
        end

        # Registers the given package set as being flavored
        def register_flavored_package_set(package_set)
            package_sets << package_set
        end

        # Declares that the package definitions created by the provided block
        # should be registered only if the current flavor is one of the listed
        # flavors
        def only_in_flavor(*flavors, &block)
            if flavors.last.kind_of?(Hash)
                options = flavors.pop
                options, other_options = Kernel.filter_options options, :strict => true
                options = options.merge(other_options)
            else
                options = { :strict => true }
            end
            flavors << options
            in_flavor(*flavors, &block)
        end

        def add_packages_to_flavors(package_set, mappings)
            register_flavored_package_set(package_set)
            mappings.each do |flavors, packages|
                if !flavors.respond_to?(:to_ary)
                    flavors = [flavors]
                end
                if !packages.respond_to?(:to_ary)
                    packages = [packages]
                end
                flavors.each do |flavor_name|
                    flavor = flavor_by_name(flavor_name)
                    flavor.removed_packages -= packages.to_set
                    flavor.default_packages[package_set.name] |= packages.to_set
                end
            end
        end

        def remove_packages_from_flavors(package_set, mappings)
            register_flavored_package_set(package_set)
            mappings.each do |flavors, packages|
                if !flavors.respond_to?(:to_ary)
                    flavors = [flavors]
                end
                if !packages.respond_to?(:to_ary)
                    packages = [packages]
                end
                flavors.each do |flavor_name|
                    flavor = flavor_by_name(flavor_name)
                    flavor.removed_packages |= packages.to_set
                end
            end
        end

        # Finalize the setup by applying the selected / removed packages to
        # Autoproj's metapackages as well as by updating the current flavor's
        # set of default packages (mainly if it is implicit)
        def finalize
            package_sets.each do |pkg_set|
                meta = Autoproj.manifest.metapackages[pkg_set.name]

                if current_flavor.implicit?
                    in_a_flavor = flavors.values.inject(Set.new) do |pkgs, other_flavor| 
                        pkgs | other_flavor.default_packages[pkg_set.name]
                    end
                    default_packages = (meta.packages.map(&:name).to_set - in_a_flavor) |
                        current_flavor.default_packages[pkg_set.name]
                else
                    default_packages = current_flavor.default_packages[pkg_set.name]
                end
                default_packages -= current_flavor.removed_packages
                default_packages = default_packages.to_set
                current_flavor.default_packages[pkg_set.name] = default_packages
                meta.packages.delete_if do |pkg|
                    !default_packages.include?(pkg.name)
                end
            end
        end

        # Verifies that the package's branch is not a flavor that they are not
        # included in (i.e. a package cannot be on the 'next' branch if it is
        # not included in the 'next' flavor). Resets the branch of these
        # packages to the given default branch
        def reset_invalid_branches_to(default_branch = 'master')
            switched_packages = Array.new
            Autoproj.manifest.each_package_definition do |pkg_def|
                pkg = pkg_def.autobuild
                next if !pkg.importer.kind_of?(Autobuild::Git)
                next if pkg.importer.branch == default_branch

                flavors = find_all_flavors_by_branch(pkg.importer.branch)
                if !flavors.empty? && !flavors.any? { |flv| flv.include?(pkg.name) }
                    vcs_raw = pkg_def.vcs.raw.reverse.
                        find { |pkg_set_name, options| options['branch'] }
                    if !vcs_raw || vcs_raw[1]['branch'] !~ /ROCK_FLAVOR|ROCK_BRANCH/
                        switched_packages << [pkg, pkg.importer.branch]
                    end
                    pkg.importer.branch = default_branch
                end
            end
            switched_packages
        end

        # Finds all packages which should have been on a branch that is the
        # flavor's branch, but are actually on a different one
        def find_all_overriden_flavored_branches
            wrong_branch = Array.new
            Autoproj.manifest.each_package_definition do |pkg_def|
                pkg = pkg_def.autobuild
                next if !pkg.importer.kind_of?(Autobuild::Git)

                if package_in_flavor?(pkg, current_flavor.name) &&
                    pkg.importer.branch != current_flavor.branch

                    # We have to check whether it is expected to be using the flavor name as
                    # its branch. Some packages are not ...
                    #
                    # To do so, we find the first package set that sets the branch to
                    # ROCK_FLAVOR *and* verify that the same package set is not overriding
                    # it to something else (to avoid false positives in case catch-all
                    # entries apply)
                    vcs = pkg_def.vcs.raw.group_by(&:first)
                    branch_should_be_flavor_name = vcs.any? do |_, info|
                        if !info.empty?
                            info.all? do |entry|
                                if entry.kind_of?(Array)
                                    vcs_options = entry[1]
                                else
                                    vcs_options = entry.vcs
                                end
                                vcs_options['branch'] && vcs_options['branch'] =~ /ROCK_FLAVOR|ROCK_BRANCH/
                            end
                        end
                    end
                    if branch_should_be_flavor_name
                        wrong_branch << pkg
                    end
                end
            end
            wrong_branch
        end

        def verify_cross_flavor_dependencies(pkg)
            if (flv = flavors[pkg.importer.branch]) && flv.include?(pkg.name)
                #Skip packages that are only on master, because packages for 'master' 
                #are not automaticly added to the master flavor. So the check would fail
                return if flv.name == 'master' 

                pkg.dependencies.each do |dep_name|
                    if !flv.include?(dep_name)
                        raise Autoproj::ConfigError, "#{pkg.name}, in flavor #{flv.name}, depends on #{dep_name} which is not included in this flavor"
                    end
                end
            end
        end
    end

    def self.flavors
        @flavors ||= FlavorManager.new
    end
end

