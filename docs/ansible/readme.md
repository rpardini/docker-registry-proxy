Add to you playbook.yml

```yaml
- hosts: docker
  gather_facts: yes
  become: yes
  become_method: sudo
  vars:
    docker_proxy_url: 192.168.66.72 #you proxy url
  roles:
    - role: docker-proxy
```