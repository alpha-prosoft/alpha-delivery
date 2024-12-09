# alpha-delivery

## Required configuration

In case you have custom certificates (Proxy, ZScaler...) you can put them in AWS parameter store under: 
```
/install/certificates/*
```

## Configuration

You can add additional policies to EC2 role
```json
{
   "builder":{
      "role":{
         "additionalPolicies": [
            "<< Policy ARN1 >>",
            "<< Policy ARN2 >>"
         ]
      }
   }
}
```

You can add custom amiFilter as well. It defaults to al2023
```json
{
   "builder":{
      "amiFilter": "amzn2-ami-al2023-*"
   }
}
```


You can configure environment as well (i.e proxy). It will be added to /etc/environment as is:
```json
{
   "builder":{
      "environment":[
         "http_proxy=http://my-proxy",
         "no_proxy=localhost"
      ]
   }
}
```

Disable public Ip address assgnment:
```json
{
   "builder":{
      "associate-public-ip-address": "False"
   }
}
```

Customize hosted zone name filter:
```json
{
   "deployer":{
      "hostedZoneFilter": "my-subdomain"
   }
}
```

Becase deployent relies on naming comminf from AWS ControllTower you may need to override names 
```
{
   "deployer":{
      "paramsSubstitutions":{
         "InternalA":"PrivateSubnet1A",
         "InternalA":"PrivateSubnet1A",
         "InternalA":"PrivateSubnet1A"
      }
   }
}
```



## How to install jenkins

```
location=$(mktemp -d) && cd $location && git clone https://github.com/alpha-prosoft/alpha-delivery.git && ./alpha-delivery/run.sh jenkins


```


## How to install gerrit

```
location=$(mktemp -d) && cd $location && git clone https://github.com/alpha-prosoft/alpha-delivery.git && ./alpha-delivery/run.sh gerrit
```
