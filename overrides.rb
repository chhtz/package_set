Rock.flavors.finalize
switched_packages = Rock.flavors.reset_invalid_branches_to('master')
wrong_branch = Rock.flavors.find_all_overriden_flavored_branches

if !switched_packages.empty?
    pkgs = switched_packages.sort_by { |pkg, _| pkg.name }.
        map do |pkg, original_branch|
            "#{pkg.name} (branch=#{original_branch})"
        end

    Autoproj.warn ""
    Autoproj.warn "the following packages are using a branch which is incompatible with the flavors"
    Autoproj.warn "they are included in (as e.g. using the 'next' branch while being included only on 'master')."
    Autoproj.warn "they got switched back to master"
    Autoproj.warn "  #{pkgs.join(", ")}"
end

wrong_branch -= switched_packages
wrong_branch = wrong_branch.find_all { |pkg| pkg.importer.branch != 'rock-rc' }
if !wrong_branch.empty?
    pkgs = wrong_branch.map { |pkg| "#{pkg.name}(#{pkg.importer.branch})" }.join(", ")

    Autoproj.warn ""
    Autoproj.warn "the following packages are using a different branch than the current flavor"
    Autoproj.warn "it is assumed that it is intentional"
    Autoproj.warn "  #{pkgs}"
end

Autoproj.env_add_path 'ROCK_BUNDLE_PATH', File.join(Autobuild.prefix, 'share', 'rock')
Autoproj.env_add_path 'ROCK_BUNDLE_PATH', File.join(Autoproj.root_dir, 'bundles')

require File.join(__dir__, 'rock', 'cxx11')
if Autoproj.respond_to?(:workspace) # autoproj 2.0
    Rock.setup_cxx11_support(Autoproj.workspace.os_package_resolver, Autoproj.config)
else
    Rock.setup_cxx11_support(Autoproj.osdeps, Autoproj.config)
end

require File.join(__dir__, 'rock', 'git_hook')
require File.join(__dir__, 'rock', 'cmake_build_type')
Autoproj.manifest.each_autobuild_package do |pkg|
    case pkg.importer
    when Autobuild::Git
        if ENV['ROCK_DISABLE_CROSS_FLAVOR_CHECKS'] != '1'
            # Finally, verify that when pkg A from flavor X depends on pkg B,
            # then B needs to be available in flavor X as well
            Rock.flavors.verify_cross_flavor_dependencies(pkg)
        end

        # Do the git hook setup in a separate setup block since we must do it
        # post-import
        setup_package(pkg.name) do
            if pkg.importer.branch == "next" || pkg.importer.branch == "stable"
                Rock.install_git_hook pkg, 'git_do_not_commit_hook', 'pre-commit'
            else
                Rock.remove_git_hook pkg, 'pre-commit'
            end
        end
    end

    case pkg
    when Autobuild::Orogen
        if !%w{tools/logger base/orogen/types base/orogen/std}.include?(pkg.name)
            pkg.optional_dependency 'tools/logger'
        end
        if Rock.flavors.current_flavor.name == 'master'
            pkg.orogen_options << '--extensions=metadata_support'
            pkg.depends_on 'tools/orogen_metadata'
        end
        if pkg.name != 'base/orogen/std'
            pkg.optional_dependency 'base/orogen/std'
            pkg.orogen_options << '--import=std'
        end
        pkg.optional_dependency 'tools/service_discovery'
        if !Autoproj.config.get('USE_OCL')
            pkg.optional_dependencies.delete 'ocl'
        end
    when Autobuild::CMake
        pkg.define "ROCK_TEST_ENABLED", pkg.test_utility.enabled?
        pkg.define "CMAKE_EXPORT_COMPILE_COMMANDS", "ON"

        pkg.define 'ROCK_USE_CXX11', Autoproj.config.get('cxx11')
    end
end

# 2014-03-12:
# temporary fix for boost bug: https://svn.boost.org/trac/boost/ticket/7979
# on debian testing
only_on 'debian' do
    setup_package 'typelib' do |pkg|
        pkg.define "GLIBC_HAVE_LONG_LONG", 1
    end  
end

