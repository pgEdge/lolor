%global pname lolor
%global sname pgedge-lolor
%global pginstdir /usr/pgsql-%{pgmajorversion}

%{!?llvm:%global llvm 1}

Name:		%{sname}_%{pgmajorversion}
Version:	%{lolor_version}
Release:	%{lolor_buildnum}%{?dist}
Summary:	Large Object LOgical Replication 
License:	PostgreSQL License
URL:		https://github.com/pgEdge/%{pname}/
Source0:	https://github.com/pgEdge/%{pname}/archive/refs/tags/v%{version}.tar.gz	

BuildRequires:	pgedge-postgresql%{pgmajorversion}-devel
Requires:	pgedge-postgresql%{pgmajorversion}-server
Provides:	%{pname}_%{pgmajorversion}

%description
lolor is a plugin in replacement for Postgres' Large Objects that makes them
compatible with Logical Replication.

%if %llvm
%package llvmjit
Summary:	Just-in-time compilation support for lolor
Requires:	%{name}%{?_isa} = %{version}-%{release}
%if 0%{?suse_version} >= 1500
BuildRequires:	llvm17-devel clang17-devel
Requires:	llvm17
%endif
%if 0%{?fedora} || 0%{?rhel} >= 8
BuildRequires:	llvm-devel >= 13.0 clang-devel >= 13.0
Requires:	llvm => 13.0
Provides:       %{pname}_%{pgmajorversion}-llvmjit
%endif

%description llvmjit
This packages provides JIT support for lolor
%endif

%prep
%setup -q -n %{pname}-%{version}

%build
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} #%{?_smp_mflags}
syft dir:%{_builddir}/%{pname}-%{version} -o cyclonedx-json > %{_builddir}/%{pname}-%{version}/%{pname}-sbom.json || exit 1

KEY_ID=$(gpg --list-secret-keys --with-colons | awk -F: '/^sec/{print $5}' | head -n 1); export KEY_ID
gpg --armor --detach-sign --output %{_builddir}/%{pname}-%{version}/%{pname}-sbom.json.asc %{_builddir}/%{pname}-%{version}/%{pname}-sbom.json || exit 1

%install
%{__rm} -rf %{buildroot}
USE_PGXS=1 PATH=%{pginstdir}/bin:$PATH %{__make} %{?_smp_mflags} install DESTDIR=%{buildroot}
mkdir -p %{buildroot}/%{pginstdir}/sbom
install -p -m 0644 %{_builddir}/%{pname}-%{version}/%{pname}-sbom.json %{buildroot}/%{pginstdir}/sbom/%{pname}-sbom.json
install -p -m 0644 %{_builddir}/%{pname}-%{version}/%{pname}-sbom.json.asc %{buildroot}/%{pginstdir}/sbom/%{pname}-sbom.json.asc

%files
%doc README.md
%license LICENSE.md
%{pginstdir}/lib/%{pname}.so
%{pginstdir}/share/extension/%{pname}.control
%{pginstdir}/share/extension/%{pname}*sql
%{pginstdir}/sbom/%{pname}-sbom.json
%{pginstdir}/sbom/%{pname}-sbom.json.asc

%if %llvm
%files llvmjit
  %{pginstdir}/lib/bitcode/%{pname}*.bc
  %{pginstdir}/lib/bitcode/%{pname}/src/*.bc
%endif

%changelog
* Thu Dec 18 2025 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.2.2
- Update lolor package to 1.2.2
* Thu Sep 25 2025 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.2.1
- Update lolor package to 1.2.1
* Mon Jul 21 2025 Muhammad Aqeel <muhammad.aqeel@pgedge.com> - 1.2
- Initial lolor package.
